package com.kemlock.app.pgp

import org.junit.Assert.assertEquals
import org.junit.Test

/** The caller of the mail provider, pinned to its original certificate (add-pgp-mail-provider, task 7.1). */
class PgpCallerTest {
    private val original = ByteArray(32) { it.toByte() }
    private val rotated = ByteArray(32) { (it + 100).toByte() }
    private val other = ByteArray(32) { (it * 3).toByte() }

    private fun caller(packages: List<String> = listOf("net.thunderbird.android"), signing: PgpSigning?) =
        PgpCaller.of(packages, ownPackage = "com.kemlock.app", signing = { signing }, label = { "Thunderbird" })

    @Test
    fun oneSignerGivesItsCertificatesDigest() {
        val result = caller(signing = PgpSigning(listOf(original), listOf(original), multipleSigners = false))
        assertEquals(PgpCaller.Pinned("net.thunderbird.android", PgpCaller.hex(original), "Thunderbird"), result)
        assertEquals("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", PgpCaller.hex(original))
    }

    @Test
    fun aRotatedLineageGivesTheFirstCertificatesDigestNotTheCurrentOnes() {
        val result = caller(signing = PgpSigning(listOf(rotated), listOf(original, rotated), multipleSigners = false))
        assertEquals(PgpCaller.hex(original), (result as PgpCaller.Pinned).cert)
    }

    @Test
    fun severalSignersAreRefused() {
        val result = caller(signing = PgpSigning(listOf(original, other), emptyList(), multipleSigners = true))
        assertEquals(PgpCaller.Refused("net.thunderbird.android", PgpCaller.SEVERAL_SIGNERS, "Thunderbird"), result)
        assertEquals("severalSigners", result.toMap()["refused"])
    }

    @Test
    fun kemlocksOwnPackageIsRefused() {
        val result = caller(packages = listOf("com.kemlock.app"), signing = PgpSigning(listOf(original), listOf(original), false))
        assertEquals(PgpCaller.ITSELF, (result as PgpCaller.Refused).reason)
    }

    @Test
    fun aUidOfNoPackageOrOfSeveralIsRefused() {
        val signing = PgpSigning(listOf(original), listOf(original), false)
        assertEquals(PgpCaller.NO_PACKAGE, (caller(packages = emptyList(), signing = signing) as PgpCaller.Refused).reason)
        assertEquals(PgpCaller.NO_PACKAGE, (caller(packages = listOf("a.b", "c.d"), signing = signing) as PgpCaller.Refused).reason)
        assertEquals(PgpCaller.NO_PACKAGE, (caller(signing = null) as PgpCaller.Refused).reason)
    }

    @Test
    fun thePinnedCallerGoesToDartAsTheMailCallerReadsIt() {
        val map = caller(signing = PgpSigning(listOf(original), listOf(original), false)).toMap()
        assertEquals(mapOf("package" to "net.thunderbird.android", "cert" to PgpCaller.hex(original), "label" to "Thunderbird"), map)
    }
}
