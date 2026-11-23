package com.kemlock.app.unlock

import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.UnrecoverableKeyException
import javax.crypto.AEADBadTagException

class UnlockErrorTest {
    @Test
    fun sendsTheCodesTheDartSideReads() {
        assertEquals(
            listOf("cancelled", "invalidated", "unavailable", "prompt", "failed"),
            listOf(
                UnlockError.Cancelled(),
                UnlockError.Invalidated(),
                UnlockError.Unavailable(),
                UnlockError.PromptFailed("x"),
                UnlockError.Failed("x"),
            ).map { it.code },
        )
        assertEquals("Keystore said no", UnlockError.Failed("Keystore said no").message)
    }

    @Test
    fun readsACancelledPromptAsCancelled() {
        for (code in listOf(BiometricPrompt.ERROR_NEGATIVE_BUTTON, BiometricPrompt.ERROR_USER_CANCELED, BiometricPrompt.ERROR_CANCELED)) {
            assertTrue("$code", UnlockError.fromPrompt(code, "Cancelled") is UnlockError.Cancelled)
        }
    }

    @Test
    fun readsAPhoneWithoutBiometricsAsUnavailable() {
        for (code in listOf(BiometricPrompt.ERROR_NO_BIOMETRICS, BiometricPrompt.ERROR_HW_NOT_PRESENT, BiometricPrompt.ERROR_HW_UNAVAILABLE)) {
            assertTrue("$code", UnlockError.fromPrompt(code, "No sensor") is UnlockError.Unavailable)
        }
    }

    // A lockout read as a Keystore failure let the old entry open the vault behind local_auth's weaker prompt
    @Test
    fun readsAnyOtherPromptErrorAsTheFailedPromptWithTheSystemsMessage() {
        val lockout = UnlockError.fromPrompt(BiometricPrompt.ERROR_LOCKOUT, "Too many attempts. Try again later.")

        assertTrue(lockout is UnlockError.PromptFailed)
        assertEquals("prompt", lockout.code)
        assertEquals("Too many attempts. Try again later.", lockout.message)
        for (code in listOf(
            BiometricPrompt.ERROR_LOCKOUT_PERMANENT,
            BiometricPrompt.ERROR_TIMEOUT,
            BiometricPrompt.ERROR_VENDOR,
            BiometricPrompt.ERROR_UNABLE_TO_PROCESS,
        )) {
            assertTrue("$code", UnlockError.fromPrompt(code, null) is UnlockError.PromptFailed)
        }
    }

    @Test
    fun readsAKeyTheKeystoreLostAsInvalidated() {
        assertTrue(UnlockError.fromKey(UnrecoverableKeyException("gone")) is UnlockError.Invalidated)
        val bad = UnlockError.fromKey(AEADBadTagException("tag mismatch"))
        assertTrue(bad is UnlockError.Failed)
        assertEquals("tag mismatch", bad.message)
        assertEquals("IllegalStateException", UnlockError.fromKey(IllegalStateException()).message)
        val invalidated = UnlockError.Invalidated()
        assertSame(invalidated, UnlockError.fromKey(invalidated))
    }

    @Test
    fun usesTheKeyOnlyWithClassThreeBiometricsEnrolled() {
        assertTrue(UnlockError.available(BiometricManager.BIOMETRIC_SUCCESS))
        for (answer in listOf(
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED,
            BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE,
            BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE,
            BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED,
        )) {
            assertFalse("$answer", UnlockError.available(answer))
        }
    }
}
