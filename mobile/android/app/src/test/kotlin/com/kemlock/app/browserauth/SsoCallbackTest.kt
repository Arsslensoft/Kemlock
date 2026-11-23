package com.kemlock.app.browserauth

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SsoCallbackTest {
    private val state = "abcdefghijklmnopqrstuvwxyz012345"

    @Test
    fun aRedirectWithTheStateIsTaken() {
        val link = "kemlock://sso?code=one-time-code&state=$state"
        assertEquals(link, SsoCallback.accept(link, state))
    }

    @Test
    fun aRedirectWithAnotherStateIsDropped() {
        assertNull(SsoCallback.accept("kemlock://sso?code=c&state=another-sign-in-state-0000000000", state))
    }

    @Test
    fun aRedirectWithNoStateIsDropped() {
        assertNull(SsoCallback.accept("kemlock://sso?code=c", state))
    }

    @Test
    fun anotherSchemeOrHostIsDropped() {
        assertNull(SsoCallback.accept("otpauth://sso?code=c&state=$state", state))
        assertNull(SsoCallback.accept("kemlock://other?code=c&state=$state", state))
        assertNull(SsoCallback.accept("https://sso?code=c&state=$state", state))
    }

    @Test
    fun aStateThatIsOnlyAPrefixIsDropped() {
        assertNull(SsoCallback.accept("kemlock://sso?code=c&state=${state}extra", state))
        assertNull(SsoCallback.accept("kemlock://sso?code=c&state=${state.dropLast(1)}", state))
    }

    @Test
    fun aLinkThatIsNotAUriIsDropped() {
        assertNull(SsoCallback.accept("kemlock://sso?code=a b&state=$state", state))
    }

    @Test
    fun theFirstOfARepeatedNameWins() {
        assertNull(SsoCallback.accept("kemlock://sso?state=wrong-state-0000000000&state=$state", state))
        assertEquals("kemlock://sso?state=$state&state=x", SsoCallback.accept("kemlock://sso?state=$state&state=x", state))
    }

    @Test
    fun theQueryIsUrlDecoded() {
        assertEquals(mapOf("a" to "b c", "d" to ""), SsoCallback.query("a=b%20c&d"))
    }

    @Test
    fun aStateIsSixteenToTwoFiftySixUrlSafeCharacters() {
        assertTrue(SsoCallback.isValidState(state))
        assertFalse(SsoCallback.isValidState("short"))
        assertFalse(SsoCallback.isValidState("x".repeat(257)))
        assertFalse(SsoCallback.isValidState("has a space in it 0000"))
    }
}
