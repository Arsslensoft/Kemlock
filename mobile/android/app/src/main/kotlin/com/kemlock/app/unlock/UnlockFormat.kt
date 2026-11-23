package com.kemlock.app.unlock

import android.security.keystore.KeyPermanentlyInvalidatedException
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import java.security.UnrecoverableKeyException

/** Why the unlock key couldn't be made or given out; [code] is what lib/platform/unlock_keys.dart reads. */
sealed class UnlockError(val code: String, message: String? = null) : Exception(message) {
    /** The person cancelled the prompt. */
    class Cancelled : UnlockError("cancelled")

    /** The key no longer opens: a fingerprint or face was added, or the key is gone. */
    class Invalidated : UnlockError("invalidated")

    /** The phone has no Class 3 biometrics enrolled, or no sensor. */
    class Unavailable : UnlockError("unavailable")

    /**
     * The prompt itself failed: a lockout after too many tries, a timeout, the sensor's own
     * error. Dart shows it and opens nothing else in its place, where a [Failed] lets an old
     * entry open the vault behind local_auth's prompt, which takes Class 2 biometrics.
     */
    class PromptFailed(message: String?) : UnlockError("prompt", message)

    /** The Keystore failed, before the prompt or after it was passed. */
    class Failed(message: String?) : UnlockError("failed", message)

    companion object {
        /** What [BiometricPrompt.AuthenticationCallback.onAuthenticationError]'s [errorCode] means. */
        fun fromPrompt(errorCode: Int, message: CharSequence?): UnlockError = when (errorCode) {
            BiometricPrompt.ERROR_NEGATIVE_BUTTON, BiometricPrompt.ERROR_USER_CANCELED, BiometricPrompt.ERROR_CANCELED -> Cancelled()
            BiometricPrompt.ERROR_NO_BIOMETRICS, BiometricPrompt.ERROR_HW_NOT_PRESENT, BiometricPrompt.ERROR_HW_UNAVAILABLE -> Unavailable()
            else -> PromptFailed(message?.toString())
        }

        /**
         * What a Keystore call that threw [e] means. A key that is permanently invalidated (new
         * biometrics) or that the Keystore can't recover any more opens nothing again.
         */
        fun fromKey(e: Throwable): UnlockError = when (e) {
            is UnlockError -> e
            is KeyPermanentlyInvalidatedException, is UnrecoverableKeyException -> Invalidated()
            else -> Failed(e.message ?: e.javaClass.simpleName)
        }

        /** Whether [BiometricManager.canAuthenticate]'s answer for Class 3 lets the key be used. */
        fun available(canAuthenticate: Int): Boolean = canAuthenticate == BiometricManager.BIOMETRIC_SUCCESS
    }
}

/** A seal key encrypted by the vault's Keystore key: the IV the Keystore chose, and the ciphertext with its tag. */
class Wrapped(val iv: ByteArray, val ct: ByteArray)

/**
 * The `wrap` the vault's entry keeps beside the sealed private key: one byte of IV length, the
 * IV, then the AES-256-GCM ciphertext and tag of the 32-byte seal key. The channel sends it in
 * base64.
 */
object UnlockWrap {
    private const val TAG_BYTES = 16

    fun pack(iv: ByteArray, ct: ByteArray): ByteArray {
        require(iv.size in 12..16) { "A GCM IV is 12 to 16 bytes" }
        require(ct.size > TAG_BYTES) { "No ciphertext" }
        return byteArrayOf(iv.size.toByte()) + iv + ct
    }

    /** The IV and ciphertext of [bytes], or null when they aren't a wrap [pack] made. */
    fun unpack(bytes: ByteArray): Wrapped? {
        if (bytes.isEmpty()) return null
        val ivLength = bytes[0].toInt()
        if (ivLength !in 12..16 || bytes.size <= 1 + ivLength + TAG_BYTES) return null
        return Wrapped(bytes.copyOfRange(1, 1 + ivLength), bytes.copyOfRange(1 + ivLength, bytes.size))
    }
}
