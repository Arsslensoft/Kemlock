package com.kemlock.app.autofill

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OtpTest {
    // The time-based accounts of test/fixtures/otp/codes.json as the copy holds them, with the
    // codes the TypeScript app made for them (test/features/autofill/autofill_fixture_test.dart).
    private val fixture = JSONObject(fixture("autofill/codes.json").readText())
    private val accounts = CopyFormat.parseCopy(fixture.getJSONObject("copy").toString()).associateBy { it.id }

    @Test
    fun makesTheCodesTheTypeScriptAppMade() {
        val codes = fixture.getJSONArray("codes")
        assertTrue(codes.length() > 80)
        for (i in 0 until codes.length()) {
            val case = codes.getJSONObject(i)
            val account = accounts.getValue(case.getString("account"))
            assertEquals(case.toString(), case.getString("code"), Otp.code(account, case.getLong("nowSec")))
        }
    }

    @Test
    fun coversEveryKindAlgorithmAndLength() {
        assertEquals(setOf(Kind.TOTP, Kind.STEAM), accounts.values.map { it.kind }.toSet())
        assertTrue(accounts.values.map { it.algorithm }.containsAll(listOf("SHA1", "SHA224", "SHA256", "SHA512")))
        assertTrue(accounts.values.map { it.digits }.containsAll(listOf(1, 5, 6, 7, 8, 9, 10)))
    }

    @Test
    fun makesRfc6238CodesWithSha384() {
        // No TypeScript vector uses SHA-384 at a time after 1970; this one is RFC 6238's SHA-256 key cut to 48 bytes.
        val key = "12345678901234567890123456789012345678901234567890".take(48).toByteArray()
        val account = CopyAccount("v", "a", "ACME", "alice", Kind.TOTP, "SHA384", 8, 30, key, emptyList())
        assertEquals(8, Otp.code(account, 59).length)
        assertEquals(Otp.code(account, 59), Otp.code(account, 30))
    }

    @Test
    fun countsTheSecondsLeftOfAWindow() {
        assertEquals(30, Otp.secondsLeft(30, 60))
        assertEquals(1, Otp.secondsLeft(30, 89))
    }
}
