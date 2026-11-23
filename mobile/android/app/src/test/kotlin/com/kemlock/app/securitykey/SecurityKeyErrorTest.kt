package com.kemlock.app.securitykey

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SecurityKeyErrorTest {
    @Test
    fun sendsTheCodesTheDartSideReads() {
        assertEquals(
            listOf("cancelled", "unavailable", "nfcOff", "denied", "removed", "timeout", "noApplication", "notDeclared", "failed"),
            listOf(
                SecurityKeyError.Cancelled(),
                SecurityKeyError.Unavailable(),
                SecurityKeyError.NfcOff(),
                SecurityKeyError.Denied(),
                SecurityKeyError.Removed(),
                SecurityKeyError.Timeout(),
                SecurityKeyError.NoApplication(),
                SecurityKeyError.NotDeclared(),
                SecurityKeyError.Failed("x"),
            ).map { it.code },
        )
        assertEquals("The key did not take the message", SecurityKeyError.Failed("The key did not take the message").message)
        assertNull(SecurityKeyError.Removed().message)
    }
}
