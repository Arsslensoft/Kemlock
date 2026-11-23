package com.kemlock.app.devicekeys

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec

/** Why a device key couldn't be made or used, as `lib/platform/device_keys.dart` reads the error codes. */
sealed class DeviceKeyError(val code: String, message: String?) : Exception(message) {
    /** The phone has no hardware key to hold it. */
    class Unavailable(message: String? = null) : DeviceKeyError("unavailable", message)

    /** There is no key under the tag. */
    class Missing(message: String? = null) : DeviceKeyError("missing", message)

    /** The Keystore failed. */
    class Failed(message: String?) : DeviceKeyError("failed", message)
}

/**
 * The parts of the device keys that need no Android, so a unit test runs them: names, the parameters the keys are made
 * with, the public point's bytes, and the AES-GCM wrap of the trusted-device key (`lib/crypto/account/trusted_device.dart`).
 */
object DeviceKeyFormat {
    const val PREFIX = "kemlock_device_"

    // The parameters of the keys: P-256 signing and AES-256-GCM wrapping, neither asking the user for anything
    const val CURVE = "secp256r1"
    const val SIGNATURE = "SHA256withECDSA"
    const val WRAP_KEY_BITS = 256
    const val GCM = "AES/GCM/NoPadding"
    const val IV_LENGTH = 12
    const val TAG_BITS = 128

    /** A sync needs no prompt: the keys need no user authentication, no biometric and no screen lock. */
    const val USER_AUTHENTICATION_REQUIRED = false

    /** StrongBox came with Android 9 (API 28); a key asks for it from there and falls back to the TEE when it is absent. */
    const val STRONGBOX_FIRST_SDK = 28

    fun asksForStrongBox(sdk: Int): Boolean = sdk >= STRONGBOX_FIRST_SDK

    /** [plain] under [secret]: the 12-byte IV the cipher made, then the ciphertext and tag. */
    fun seal(secret: SecretKey, plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(GCM).apply { init(Cipher.ENCRYPT_MODE, secret) }
        return cipher.iv + cipher.doFinal(plain)
    }

    /** What [seal] returned, opened. A change to it, or another key, throws. */
    fun open(secret: SecretKey, wrapped: ByteArray): ByteArray {
        if (wrapped.size <= IV_LENGTH) throw DeviceKeyError.Failed("The wrapped key is too short")
        val cipher = Cipher.getInstance(GCM).apply {
            init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(TAG_BITS, wrapped.copyOfRange(0, IV_LENGTH)))
        }
        return cipher.doFinal(wrapped, IV_LENGTH, wrapped.size - IV_LENGTH)
    }
    private val TAG = Regex("^[A-Za-z0-9_.:-]{1,128}$")

    fun isValidTag(tag: String): Boolean = TAG.matches(tag)

    /** The Keystore alias of the key under [tag]. */
    fun alias(tag: String): String = PREFIX + tag

    /** A P-256 public point as X9.63 uncompressed: 0x04, x, y, each coordinate 32 bytes. */
    fun uncompressedPoint(x: BigInteger, y: BigInteger): ByteArray = byteArrayOf(4) + fixed(x) + fixed(y)

    private fun fixed(value: BigInteger): ByteArray {
        val bytes = value.toByteArray()
        // BigInteger adds a sign byte to a value whose top bit is set
        val unsigned = if (bytes.size > 32 && bytes[0] == 0.toByte()) bytes.copyOfRange(1, bytes.size) else bytes
        require(unsigned.size <= 32) { "a P-256 coordinate is at most 32 bytes" }
        return ByteArray(32 - unsigned.size) + unsigned
    }
}

/**
 * The Keystore keys behind the Kemlock Server session, alias `kemlock_device_<tag>`: an EC P-256 key that signs
 * DPoP proofs (SHA-256 with ECDSA), and an AES-256-GCM key that wraps the trusted-device key. Both are in
 * StrongBox where the phone has one, then in the TEE, and need no user authentication, so a sync needs no prompt.
 * A Keystore that keeps its keys in software (an emulator) is no hardware key: the key is deleted and the phone
 * answers `unavailable`, and Dart uses its own software key.
 */
object DeviceKeystore {
    private const val STORE = "AndroidKeyStore"

    private fun keyStore(): KeyStore = KeyStore.getInstance(STORE).apply { load(null) }

    /** Whether the phone's Keystore can hold keys in hardware at all; whether it does is known once one is made. */
    fun hardware(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M

    /** Makes the signing key under [tag], replacing any earlier one, and returns its public point. */
    fun createSigning(tag: String): ByteArray {
        delete(tag)
        val alias = DeviceKeyFormat.alias(tag)
        try {
            val pair = try {
                generateSigning(alias, strongBox = DeviceKeyFormat.asksForStrongBox(Build.VERSION.SDK_INT))
            } catch (e: Exception) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && e is StrongBoxUnavailableException) generateSigning(alias, strongBox = false) else throw e
            }
            val info = KeyFactory.getInstance(pair.private.algorithm, STORE).getKeySpec(pair.private, KeyInfo::class.java)
            if (!inHardware(info)) throw DeviceKeyError.Unavailable("The Keystore keeps its keys in software")
            val point = (pair.public as ECPublicKey).w
            return DeviceKeyFormat.uncompressedPoint(point.affineX, point.affineY)
        } catch (e: Exception) {
            runCatching { delete(tag) }
            throw e
        }
    }

    private fun generateSigning(alias: String, strongBox: Boolean): java.security.KeyPair {
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec(DeviceKeyFormat.CURVE))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(DeviceKeyFormat.USER_AUTHENTICATION_REQUIRED)
        if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) spec.setIsStrongBoxBacked(true)
        return KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, STORE).run {
            initialize(spec.build())
            generateKeyPair()
        }
    }

    /** Makes the wrapping key under [tag], replacing any earlier one. */
    fun createWrapping(tag: String) {
        delete(tag)
        val alias = DeviceKeyFormat.alias(tag)
        try {
            val key = try {
                generateWrapping(alias, strongBox = DeviceKeyFormat.asksForStrongBox(Build.VERSION.SDK_INT))
            } catch (e: Exception) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && e is StrongBoxUnavailableException) generateWrapping(alias, strongBox = false) else throw e
            }
            val info = SecretKeyFactory.getInstance(key.algorithm, STORE).getKeySpec(key, KeyInfo::class.java) as KeyInfo
            if (!inHardware(info)) throw DeviceKeyError.Unavailable("The Keystore keeps its keys in software")
        } catch (e: Exception) {
            runCatching { delete(tag) }
            throw e
        }
    }

    private fun generateWrapping(alias: String, strongBox: Boolean): SecretKey {
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(DeviceKeyFormat.WRAP_KEY_BITS)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUserAuthenticationRequired(DeviceKeyFormat.USER_AUTHENTICATION_REQUIRED)
        if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) spec.setIsStrongBoxBacked(true)
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, STORE).run {
            init(spec.build())
            generateKey()
        }
    }

    @Suppress("DEPRECATION")
    private fun inHardware(info: KeyInfo): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) info.securityLevel != KeyProperties.SECURITY_LEVEL_SOFTWARE else info.isInsideSecureHardware

    /** The signing key's public point, or null when there is no key under [tag]. */
    fun point(tag: String): ByteArray? {
        val certificate = keyStore().getCertificate(DeviceKeyFormat.alias(tag)) ?: return null
        val point = (certificate.publicKey as ECPublicKey).w
        return DeviceKeyFormat.uncompressedPoint(point.affineX, point.affineY)
    }

    /** Whether a key, of either use, is under [tag]. */
    fun exists(tag: String): Boolean = keyStore().containsAlias(DeviceKeyFormat.alias(tag))

    /** An ECDSA signature of [message], SHA-256, DER encoded. */
    fun sign(tag: String, message: ByteArray): ByteArray {
        val key = keyStore().getKey(DeviceKeyFormat.alias(tag), null) as? PrivateKey ?: throw DeviceKeyError.Missing()
        return Signature.getInstance(DeviceKeyFormat.SIGNATURE).run {
            initSign(key)
            update(message)
            sign()
        }
    }

    /** [key] under the wrapping key: the 12-byte IV the Keystore made, then the ciphertext and tag. */
    fun wrap(tag: String, key: ByteArray): ByteArray = DeviceKeyFormat.seal(secretKey(tag), key)

    /** What [wrap] returned, opened. A change to it, or another key, fails. */
    fun unwrap(tag: String, wrapped: ByteArray): ByteArray = DeviceKeyFormat.open(secretKey(tag), wrapped)

    private fun secretKey(tag: String): SecretKey =
        keyStore().getKey(DeviceKeyFormat.alias(tag), null) as? SecretKey ?: throw DeviceKeyError.Missing()

    fun delete(tag: String) {
        val store = keyStore()
        val alias = DeviceKeyFormat.alias(tag)
        if (store.containsAlias(alias)) store.deleteEntry(alias)
    }
}

/**
 * The app's side of `com.kemlock.app/device_keys` (lib/platform/device_keys.dart). Making a StrongBox key can take
 * seconds, so Keystore work runs off the main thread.
 */
class DeviceKeyChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "com.kemlock.app/device_keys")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "hardware") return result.success(DeviceKeystore.hardware())
        val tag = call.argument<String>("tag")
        if (tag == null || !DeviceKeyFormat.isValidTag(tag)) return result.error("failed", "No valid tag", null)
        when (call.method) {
            "create" -> {
                val use = call.argument<String>("use")
                background(result) {
                    when (use) {
                        "signing" -> mapOf("protection" to "keystore", "point" to DeviceKeystore.createSigning(tag))
                        "wrapping" -> {
                            DeviceKeystore.createWrapping(tag)
                            mapOf("protection" to "keystore")
                        }
                        else -> throw DeviceKeyError.Failed("Unknown use")
                    }
                }
            }
            "info" -> background(result) {
                if (!DeviceKeystore.exists(tag)) null else mapOf("protection" to "keystore", "point" to DeviceKeystore.point(tag))
            }
            "sign" -> {
                val message = call.argument<ByteArray>("message") ?: return result.error("failed", "No message", null)
                background(result) { DeviceKeystore.sign(tag, message) }
            }
            "wrap" -> {
                val data = call.argument<ByteArray>("data") ?: return result.error("failed", "No data", null)
                background(result) { DeviceKeystore.wrap(tag, data) }
            }
            "unwrap" -> {
                val data = call.argument<ByteArray>("data") ?: return result.error("failed", "No data", null)
                background(result) { DeviceKeystore.unwrap(tag, data) }
            }
            "delete" -> background(result) { DeviceKeystore.delete(tag) }
            else -> result.notImplemented()
        }
    }

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        worker.execute {
            try {
                val answer = work()
                main.post { result.success(answer) }
            } catch (e: DeviceKeyError) {
                main.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                main.post { result.error("failed", e.message, null) }
            }
        }
    }
}
