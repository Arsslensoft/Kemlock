package com.kemlock.app.clipboard

import com.kemlock.app.engine.SharedEngineActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SecretClipTest {
    @Test
    fun marksTheClipUnderItsNameForTheSdkLevel() {
        // Android 13 made the extra a constant, under the name it had before
        assertEquals("android.content.extra.IS_SENSITIVE", SecretClip.sensitiveExtra(33))
        assertEquals("android.content.extra.IS_SENSITIVE", SecretClip.sensitiveExtra(36))
        for (sdk in 24..32) assertEquals("$sdk", SecretClip.OLD_SENSITIVE_EXTRA, SecretClip.sensitiveExtra(sdk))
        assertEquals("Kemlock", SecretClip.LABEL)
    }

    @Test
    fun namesACopyByItsTimestampFromAndroid8() {
        assertEquals("1763290000123", SecretClip.token(26, 1763290000123))
        assertEquals("1763290000123", SecretClip.token(36, 1763290000123))
        assertEquals("", SecretClip.token(25, 1763290000123))
        assertEquals("", SecretClip.token(33, null))
    }

    @Test
    fun clearsItsOwnCopy() {
        assertTrue(SecretClip.shouldClear("1763290000123", readable = true, timestamp = 1763290000123))
    }

    @Test
    fun leavesWhatWasCopiedSince() {
        assertFalse(SecretClip.shouldClear("1763290000123", readable = true, timestamp = 1763290010456))
        assertFalse(SecretClip.shouldClear("1763290000123", readable = true, timestamp = null))
    }

    @Test
    fun clearsBlindlyWhenAndroidWontSayWhatIsThere() {
        assertTrue(SecretClip.shouldClear("1763290000123", readable = false, timestamp = null))
        // Before Android 8 a copy has no token
        assertTrue(SecretClip.shouldClear("", readable = true, timestamp = null))
    }

    @Test
    fun theChannelIsNotLetGoWithAnActivity() {
        // The process's engine serves it (KemlockEngine), so the timer clears after the main screen closed
        assertFalse("com.kemlock.app/clipboard" in SharedEngineActivity.ACTIVITY_CHANNELS)
    }
}
