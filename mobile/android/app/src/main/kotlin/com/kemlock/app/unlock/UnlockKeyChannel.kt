package com.kemlock.app.unlock

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.kemlock.app.R
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The Keystore keys behind biometric unlock: an AES-256-GCM key per vault, alias
 * `kemlock_unlock_<vault>`, in StrongBox where the phone has one. Each use needs its own Class 3
 * biometric prompt (no time window after it), and the key is invalidated when a fingerprint or
 * face is added. It encrypts the vault's 32-byte seal key; the vault's entry keeps the result,
 * [UnlockWrap], and the key never leaves the Keystore.
 */
object UnlockKeystore {
    private const val STORE = "AndroidKeyStore"
    const val PREFIX = "kemlock_unlock_"
    private const val GCM = "AES/GCM/NoPadding"

    private fun keyStore(): KeyStore = KeyStore.getInstance(STORE).apply { load(null) }

    fun alias(vault: String) = PREFIX + vault

    /** Makes [vault]'s key, replacing any earlier one. StrongBox first, then the TEE, as AutofillKey does. */
    fun create(vault: String) {
        delete(vault)
        try {
            generate(vault, strongBox = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
        } catch (e: Exception) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && e is StrongBoxUnavailableException) generate(vault, strongBox = false) else throw e
        }
    }

    private fun generate(vault: String, strongBox: Boolean) {
        val spec = KeyGenParameterSpec.Builder(alias(vault), KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // 0 seconds: each operation needs the prompt made for it
            spec.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        } else {
            @Suppress("DEPRECATION")
            spec.setUserAuthenticationValidityDurationSeconds(-1)
        }
        if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) spec.setIsStrongBoxBacked(true)
        KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, STORE).run {
            init(spec.build())
            generateKey()
        }
    }

    private fun key(vault: String): SecretKey = keyStore().getKey(alias(vault), null) as? SecretKey ?: throw UnlockError.Invalidated()

    /** A cipher that encrypts with [vault]'s key once a prompt authorises it. */
    fun encrypter(vault: String): Cipher = Cipher.getInstance(GCM).apply { init(Cipher.ENCRYPT_MODE, key(vault)) }

    /** A cipher that decrypts [wrapped] with [vault]'s key once a prompt authorises it. */
    fun decrypter(vault: String, wrapped: Wrapped): Cipher =
        Cipher.getInstance(GCM).apply { init(Cipher.DECRYPT_MODE, key(vault), GCMParameterSpec(128, wrapped.iv)) }

    fun delete(vault: String) {
        val store = keyStore()
        if (store.containsAlias(alias(vault))) store.deleteEntry(alias(vault))
    }

    /** Deletes every vault's key, and no other key of the app (the autofill key stays). */
    fun deleteAll() {
        val store = keyStore()
        store.aliases().toList().filter { it.startsWith(PREFIX) }.forEach(store::deleteEntry)
    }
}

/**
 * The app's side of `com.kemlock.app/unlock` (lib/platform/unlock_keys.dart). The prompt is a
 * [BiometricPrompt] with a [BiometricPrompt.CryptoObject], Class 3 only, shown over the app's
 * activity: on Android it has to be the prompt that authorises the key, which local_auth can't
 * show. Making a StrongBox key can take seconds, so Keystore work runs off the main thread.
 *
 * It also answers `elapsed`, [SystemClock.elapsedRealtime] in milliseconds, the clock auto-lock
 * counts idle time with.
 */
class UnlockKeyChannel(private val activity: FragmentActivity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "com.kemlock.app/unlock")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val vault = call.argument<String>("vault")
        val reason = call.argument<String>("reason").orEmpty()
        when (call.method) {
            // Auto-lock's clock: it counts deep sleep, and setting the date doesn't move it
            "elapsed" -> result.success(SystemClock.elapsedRealtime())
            "status" -> result.success(status())
            "seal" -> {
                val key = call.argument<ByteArray>("key")
                if (vault == null || key == null || key.size != 32) return fail(result, UnlockError.Failed("No vault or key"))
                seal(vault, key, reason, result)
            }
            "open" -> {
                if (vault == null) return fail(result, UnlockError.Failed("No vault"))
                open(vault, call.argument<String>("wrap").orEmpty(), reason, result)
            }
            "delete" -> background(result) { vault?.let(UnlockKeystore::delete) }
            "deleteAll" -> background(result) { UnlockKeystore.deleteAll() }
            else -> result.notImplemented()
        }
    }

    private fun status(): Boolean = UnlockError.available(BiometricManager.from(activity).canAuthenticate(BIOMETRIC_STRONG))

    private fun seal(vault: String, key: ByteArray, reason: String, result: MethodChannel.Result) {
        if (!status()) return fail(result, UnlockError.Unavailable())
        worker.execute {
            val cipher = try {
                UnlockKeystore.create(vault)
                UnlockKeystore.encrypter(vault)
            } catch (e: Exception) {
                runCatching { UnlockKeystore.delete(vault) }
                main.post { fail(result, UnlockError.fromKey(e)) }
                return@execute
            }
            main.post {
                prompt(reason, cipher, result, onFailure = { runCatching { UnlockKeystore.delete(vault) } }) { authorised ->
                    val ct = authorised.doFinal(key)
                    Base64.encodeToString(UnlockWrap.pack(authorised.iv, ct), Base64.NO_WRAP)
                }
            }
        }
    }

    private fun open(vault: String, wrap: String, reason: String, result: MethodChannel.Result) {
        val wrapped = runCatching { UnlockWrap.unpack(Base64.decode(wrap, Base64.DEFAULT)) }.getOrNull()
            ?: return fail(result, UnlockError.Failed("The entry's wrap can't be read"))
        worker.execute {
            val cipher = try {
                UnlockKeystore.decrypter(vault, wrapped)
            } catch (e: Exception) {
                val error = UnlockError.fromKey(e)
                // An invalidated key never opens again
                if (error is UnlockError.Invalidated) runCatching { UnlockKeystore.delete(vault) }
                main.post { fail(result, error) }
                return@execute
            }
            main.post { prompt(reason, cipher, result) { authorised -> authorised.doFinal(wrapped.ct) } }
        }
    }

    /** Shows the prompt for [cipher], then answers with what [use] makes of the authorised cipher. */
    private fun prompt(
        reason: String,
        cipher: Cipher,
        result: MethodChannel.Result,
        onFailure: () -> Unit = {},
        use: (Cipher) -> Any,
    ) {
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(reason)
            .setNegativeButtonText(activity.getString(R.string.unlock_cancel))
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .setConfirmationRequired(false)
            .build()
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(authenticated: BiometricPrompt.AuthenticationResult) {
                val authorised = authenticated.cryptoObject?.cipher ?: return failed(UnlockError.Failed("The prompt gave back no key"))
                try {
                    result.success(use(authorised))
                } catch (e: Exception) {
                    failed(UnlockError.fromKey(e))
                }
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) = failed(UnlockError.fromPrompt(errorCode, errString))

            private fun failed(error: UnlockError) {
                onFailure()
                fail(result, error)
            }
        }
        try {
            BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), callback).authenticate(info, BiometricPrompt.CryptoObject(cipher))
        } catch (e: Exception) {
            onFailure()
            fail(result, UnlockError.fromKey(e))
        }
    }

    private fun fail(result: MethodChannel.Result, error: UnlockError) = result.error(error.code, error.message, null)

    private fun background(result: MethodChannel.Result, work: () -> Unit) {
        worker.execute {
            try {
                work()
                main.post { result.success(null) }
            } catch (e: Exception) {
                main.post { fail(result, UnlockError.fromKey(e)) }
            }
        }
    }
}
