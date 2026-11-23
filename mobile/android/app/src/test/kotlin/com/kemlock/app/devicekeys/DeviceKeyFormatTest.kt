package com.kemlock.app.devicekeys

import java.math.BigInteger
import javax.crypto.AEADBadTagException
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class DeviceKeyFormatTest {
    @Test
    fun namesTheKeyAfterItsTagUnderTheAppsPrefix() {
        assertEquals("kemlock_device_dpop.main.acct-1", DeviceKeyFormat.alias("dpop.main.acct-1"))
        // The unlock keys have their own prefix, so deleting one kind never touches the other
        assertFalse(DeviceKeyFormat.alias("x").startsWith("kemlock_unlock_"))
    }

    @Test
    fun takesOnlyTagsOfPlainCharactersAndALimitedLength() {
        assertTrue(DeviceKeyFormat.isValidTag("dpop.0a1b:vault-1_x"))
        assertFalse(DeviceKeyFormat.isValidTag(""))
        assertFalse(DeviceKeyFormat.isValidTag("a/b"))
        assertFalse(DeviceKeyFormat.isValidTag("a b"))
        assertFalse(DeviceKeyFormat.isValidTag("x".repeat(129)))
    }

    @Test
    fun writesAPublicPointAsX963WithBothCoordinatesPadded() {
        val x = BigInteger.ONE
        val y = BigInteger("ff".repeat(32), 16)

        val point = DeviceKeyFormat.uncompressedPoint(x, y)

        assertEquals(65, point.size)
        assertEquals(4.toByte(), point[0])
        assertArrayEquals(ByteArray(31) + byteArrayOf(1), point.copyOfRange(1, 33))
        assertArrayEquals(ByteArray(32) { 0xff.toByte() }, point.copyOfRange(33, 65))
    }

    @Test
    fun refusesACoordinateOverThirtyTwoBytes() {
        try {
            DeviceKeyFormat.uncompressedPoint(BigInteger.ONE.shiftLeft(256), BigInteger.ONE)
            fail("a 33-byte coordinate was taken")
        } catch (expected: IllegalArgumentException) {
            // refused
        }
    }

    @Test
    fun sendsTheCodesTheDartSideReads() {
        assertEquals(
            listOf("unavailable", "missing", "failed"),
            listOf(DeviceKeyError.Unavailable(), DeviceKeyError.Missing(), DeviceKeyError.Failed("x")).map { it.code },
        )
        assertEquals("Keystore said no", DeviceKeyError.Failed("Keystore said no").message)
    }

    @Test
    fun makesAP256SigningKeyAndAnAes256GcmWrappingKeyThatAskForNoUser() {
        assertEquals("secp256r1", DeviceKeyFormat.CURVE)
        assertEquals("SHA256withECDSA", DeviceKeyFormat.SIGNATURE)
        assertEquals(256, DeviceKeyFormat.WRAP_KEY_BITS)
        assertEquals("AES/GCM/NoPadding", DeviceKeyFormat.GCM)
        assertEquals(12, DeviceKeyFormat.IV_LENGTH)
        assertEquals(128, DeviceKeyFormat.TAG_BITS)
        // A sync needs no prompt, so neither key asks for a biometric or the screen lock
        assertFalse(DeviceKeyFormat.USER_AUTHENTICATION_REQUIRED)
    }

    @Test
    fun asksForStrongBoxFromAndroid9AndLeavesOlderPhonesToTheTee() {
        assertFalse(DeviceKeyFormat.asksForStrongBox(27))
        assertTrue(DeviceKeyFormat.asksForStrongBox(28))
        assertTrue(DeviceKeyFormat.asksForStrongBox(35))
    }

    private fun aesKey(): SecretKey = KeyGenerator.getInstance("AES").apply { init(DeviceKeyFormat.WRAP_KEY_BITS) }.generateKey()

    @Test
    fun wrapsAKeyAsTheIvThenTheCiphertextAndTagAndOpensItAgain() {
        val secret = aesKey()
        val key = ByteArray(32) { it.toByte() }

        val wrapped = DeviceKeyFormat.seal(secret, key)

        assertEquals(DeviceKeyFormat.IV_LENGTH + key.size + DeviceKeyFormat.TAG_BITS / 8, wrapped.size)
        assertArrayEquals(key, DeviceKeyFormat.open(secret, wrapped))
    }

    @Test
    fun wrapsTheSameKeyTwiceToDifferentBytes() {
        val secret = aesKey()
        val key = ByteArray(32) { 7 }

        assertFalse(DeviceKeyFormat.seal(secret, key).contentEquals(DeviceKeyFormat.seal(secret, key)))
    }

    @Test
    fun anotherWrappingKeyOpensNothing() {
        val wrapped = DeviceKeyFormat.seal(aesKey(), ByteArray(32) { 1 })

        try {
            DeviceKeyFormat.open(aesKey(), wrapped)
            fail("another key opened the wrap")
        } catch (expected: AEADBadTagException) {
            // refused
        }
    }

    @Test
    fun aChangedByteOpensNothing() {
        val secret = aesKey()
        val wrapped = DeviceKeyFormat.seal(secret, ByteArray(32) { 1 })
        wrapped[wrapped.size - 1] = (wrapped[wrapped.size - 1].toInt() xor 1).toByte()

        try {
            DeviceKeyFormat.open(secret, wrapped)
            fail("a changed wrap was opened")
        } catch (expected: AEADBadTagException) {
            // refused
        }
    }

    @Test
    fun aWrapThatIsOnlyAnIvIsRefusedAsFailedNotAsAnotherError() {
        try {
            DeviceKeyFormat.open(aesKey(), ByteArray(DeviceKeyFormat.IV_LENGTH))
            fail("a wrap with no ciphertext was opened")
        } catch (expected: DeviceKeyError.Failed) {
            assertEquals("failed", expected.code)
        }
    }
}
