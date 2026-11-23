package com.kemlock.app.unlock

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class UnlockWrapTest {
    private val iv = ByteArray(12) { it.toByte() }
    private val ct = ByteArray(48) { (100 + it).toByte() }

    @Test
    fun keepsTheIvLengthTheIvAndTheCiphertextInThatOrder() {
        val packed = UnlockWrap.pack(iv, ct)

        assertEquals(1 + 12 + 48, packed.size)
        assertEquals(12, packed[0].toInt())
        assertArrayEquals(iv, packed.copyOfRange(1, 13))
        assertArrayEquals(ct, packed.copyOfRange(13, packed.size))
    }

    @Test
    fun givesBackWhatItPacked() {
        val wrapped = UnlockWrap.unpack(UnlockWrap.pack(iv, ct))!!

        assertArrayEquals(iv, wrapped.iv)
        assertArrayEquals(ct, wrapped.ct)
    }

    @Test
    fun opensASealKeyEncryptedAsTheKeystoreDoes() {
        // AES-256-GCM with a 12-byte IV and a 128-bit tag, as the Keystore key encrypts the seal key
        val aes = SecretKeySpec(ByteArray(32).also(SecureRandom()::nextBytes), "AES")
        val sealKey = ByteArray(32).also(SecureRandom()::nextBytes)
        val encrypt = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, aes) }
        val packed = UnlockWrap.pack(encrypt.iv, encrypt.doFinal(sealKey))

        val wrapped = UnlockWrap.unpack(packed)!!
        val decrypt = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, aes, GCMParameterSpec(128, wrapped.iv)) }

        assertArrayEquals(sealKey, decrypt.doFinal(wrapped.ct))
    }

    @Test
    fun refusesWhatItDidNotPack() {
        assertNull(UnlockWrap.unpack(ByteArray(0)))
        assertNull(UnlockWrap.unpack(byteArrayOf(11) + ByteArray(40)))
        assertNull(UnlockWrap.unpack(byteArrayOf(17) + ByteArray(40)))
        assertNull(UnlockWrap.unpack(byteArrayOf(12) + ByteArray(12 + 16)))
        assertThrows(IllegalArgumentException::class.java) { UnlockWrap.pack(ByteArray(8), ct) }
        assertThrows(IllegalArgumentException::class.java) { UnlockWrap.pack(iv, ByteArray(16)) }
    }
}
