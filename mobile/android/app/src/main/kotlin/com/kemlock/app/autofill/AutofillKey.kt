package com.kemlock.app.autofill

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.security.keystore.UserNotAuthenticatedException
import androidx.annotation.RequiresApi
import org.json.JSONObject
import java.security.GeneralSecurityException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.spec.MGF1ParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.crypto.spec.SecretKeySpec

/** The key can't be used any more: biometrics were added or removed since it was made. */
class KeyInvalidatedException : Exception("The autofill key was invalidated")

/**
 * The key the autofill copy is encrypted to: an RSA key pair in the Android Keystore, in
 * StrongBox where the phone has one, and only from Android 11: before, Keystore opens a key with
 * a validity duration with the PIN as well, and a fingerprint added after it was made doesn't
 * invalidate it, so whoever knows the PIN could add one and read every vault's codes through a
 * fill (values/autofill.xml). Encrypting needs only its public half, so the app writes the copy
 * without asking for anything. Decrypting needs strong biometrics, and only those, in the last
 * [AUTH_SECONDS] seconds, so the fill screen can open every vault's copy and the remembered
 * picks after one prompt, and the key stops working once biometrics are added or removed.
 *
 * Each file is sealed with a fresh AES-256-GCM key, which RSA-OAEP wraps. Keystore takes
 * OAEP with SHA-256 only with MGF1 over SHA-1 on older Android, so that is what both ends use.
 */
@RequiresApi(Build.VERSION_CODES.O)
object AutofillKey {
    private const val STORE = "AndroidKeyStore"
    private const val ALIAS = "kemlock_autofill"
    const val AUTH_SECONDS = 10

    private const val RSA = "RSA/ECB/OAEPWithSHA-256AndMGF1Padding"
    private val oaep = OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT)
    private val random = SecureRandom()

    private fun keyStore(): KeyStore = KeyStore.getInstance(STORE).apply { load(null) }

    fun exists(): Boolean = keyStore().containsAlias(ALIAS)

    /**
     * Whether the key is there and still usable: false once biometrics changed since it was made,
     * and for a key that opens with the PIN too, which goes the same way.
     */
    fun isValid(): Boolean {
        if (!exists() || !biometricOnly()) return false
        return try {
            Cipher.getInstance(RSA).init(Cipher.DECRYPT_MODE, privateKey(), oaep)
            true
        } catch (_: KeyPermanentlyInvalidatedException) {
            false
        } catch (_: UserNotAuthenticatedException) {
            true
        }
    }

    /**
     * Whether the key opens with strong biometrics alone. One a Kemlock made on Android 8 to 10
     * outlives the phone's update to 11 and opens with the PIN as well, as it was made to: it is
     * no longer valid, so its copies go and the app writes them again under a new key. On a phone
     * whose Keystore won't describe the key, it is taken as before, for valid.
     */
    private fun biometricOnly(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        return try {
            val key = privateKey()
            val info = KeyFactory.getInstance(key.algorithm, STORE).getKeySpec(key, KeyInfo::class.java)
            info.userAuthenticationType == KeyProperties.AUTH_BIOMETRIC_STRONG
        } catch (_: GeneralSecurityException) {
            true
        }
    }

    /** Makes the key. Throws when the phone has no strong biometrics enrolled. */
    fun create() {
        try {
            generate(strongBox = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
        } catch (e: Exception) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && e is StrongBoxUnavailableException) generate(strongBox = false) else throw e
        }
    }

    fun delete() {
        val store = keyStore()
        if (store.containsAlias(ALIAS)) store.deleteEntry(ALIAS)
    }

    private fun generate(strongBox: Boolean) {
        // Below Android 11 a key with a validity duration opens with the PIN too, and a fingerprint
        // added since doesn't invalidate it: never made there (values/autofill.xml)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) throw UnsupportedOperationException("Autofill needs Android 11")
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(2048)
            .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA1)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
            .setUserAuthenticationParameters(AUTH_SECONDS, KeyProperties.AUTH_BIOMETRIC_STRONG)
        if (strongBox) spec.setIsStrongBoxBacked(true)
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, STORE).run {
            initialize(spec.build())
            generateKeyPair()
        }
    }

    private fun publicKey(): PublicKey {
        // Rebuilt outside the Keystore, so encrypting goes through the ordinary provider.
        val stored = keyStore().getCertificate(ALIAS).publicKey
        return KeyFactory.getInstance(stored.algorithm).generatePublic(X509EncodedKeySpec(stored.encoded))
    }

    private fun privateKey(): PrivateKey = keyStore().getKey(ALIAS, null) as PrivateKey

    /** [plain] sealed to the key, as the JSON envelope the files hold. */
    fun seal(plain: ByteArray): String {
        val aes = ByteArray(32).also(random::nextBytes)
        val nonce = ByteArray(12).also(random::nextBytes)
        val gcm = Cipher.getInstance("AES/GCM/NoPadding")
        gcm.init(Cipher.ENCRYPT_MODE, SecretKeySpec(aes, "AES"), GCMParameterSpec(128, nonce))
        val ct = gcm.doFinal(plain)
        val rsa = Cipher.getInstance(RSA)
        rsa.init(Cipher.ENCRYPT_MODE, publicKey(), oaep)
        val wrapped = rsa.doFinal(aes)
        aes.fill(0)
        val b64 = Base64.getEncoder()
        return JSONObject()
            .put("v", FORMAT_VERSION)
            .put("key", b64.encodeToString(wrapped))
            .put("nonce", b64.encodeToString(nonce))
            .put("ct", b64.encodeToString(ct))
            .toString()
    }

    /**
     * Opens an envelope [seal] made. Needs biometrics in the last [AUTH_SECONDS] seconds;
     * throws [KeyInvalidatedException] once biometrics changed since the key was made.
     */
    fun open(envelope: String): ByteArray {
        val o = JSONObject(envelope)
        if (o.optInt("v") != FORMAT_VERSION) throw UnsupportedFormatException("Envelope ${o.optInt("v")}")
        val b64 = Base64.getDecoder()
        val rsa = Cipher.getInstance(RSA)
        try {
            rsa.init(Cipher.DECRYPT_MODE, privateKey(), oaep)
        } catch (_: KeyPermanentlyInvalidatedException) {
            throw KeyInvalidatedException()
        }
        val aes = rsa.doFinal(b64.decode(o.getString("key")))
        try {
            val gcm = Cipher.getInstance("AES/GCM/NoPadding")
            gcm.init(Cipher.DECRYPT_MODE, SecretKeySpec(aes, "AES"), GCMParameterSpec(128, b64.decode(o.getString("nonce"))))
            return gcm.doFinal(b64.decode(o.getString("ct")))
        } finally {
            aes.fill(0)
        }
    }
}
