package com.kemlock.app.autofill

import java.nio.ByteBuffer
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * The codes of the autofill copy's accounts, made as lib/features/accounts/otp.dart makes
 * them: RFC 6238 TOTP over RFC 4226 truncation, and Steam Guard's five characters. The app
 * leaves out of the copy any account whose secret, algorithm, digits or period would make a
 * code another way.
 */
object Otp {
    private const val STEAM_ALPHABET = "23456789BCDFGHJKMNPQRTVWXY"

    private val macs = mapOf(
        "SHA1" to "HmacSHA1",
        "SHA224" to "HmacSHA224",
        "SHA256" to "HmacSHA256",
        "SHA384" to "HmacSHA384",
        "SHA512" to "HmacSHA512",
    )

    /** The code of [account] for the window holding [nowSec], Unix time in whole seconds. */
    fun code(account: CopyAccount, nowSec: Long): String {
        val counter = Math.floorDiv(nowSec, account.period.toLong())
        return when (account.kind) {
            Kind.STEAM -> steam(account.key, counter)
            Kind.TOTP -> hotp(account.algorithm, account.key, account.digits, counter)
        }
    }

    /** Seconds left before the code of a [period]-second window changes, at [nowSec]: 1 to [period]. */
    fun secondsLeft(period: Int, nowSec: Long): Int = period - Math.floorMod(nowSec, period.toLong()).toInt()

    private fun hotp(algorithm: String, key: ByteArray, digits: Int, counter: Long): String {
        val value = truncate(hmac(algorithm, key, counter)).toLong()
        // Any value fits in 10 digits; 10 or more pad it with zeros
        val code = if (digits >= 10) value else value % pow10(digits)
        return code.toString().padStart(digits, '0')
    }

    private fun steam(key: ByteArray, counter: Long): String {
        var value = truncate(hmac("SHA1", key, counter))
        val code = StringBuilder()
        repeat(5) {
            code.append(STEAM_ALPHABET[value % STEAM_ALPHABET.length])
            value /= STEAM_ALPHABET.length
        }
        return code.toString()
    }

    private fun hmac(algorithm: String, key: ByteArray, counter: Long): ByteArray {
        val name = macs[algorithm] ?: throw IllegalArgumentException("No HMAC for $algorithm")
        val mac = Mac.getInstance(name)
        mac.init(SecretKeySpec(key, name))
        return mac.doFinal(ByteBuffer.allocate(8).putLong(counter).array())
    }

    private fun truncate(mac: ByteArray): Int {
        val o = mac.last().toInt() and 0xf
        return (mac[o].toInt() and 0x7f) shl 24 or
            ((mac[o + 1].toInt() and 0xff) shl 16) or
            ((mac[o + 2].toInt() and 0xff) shl 8) or
            (mac[o + 3].toInt() and 0xff)
    }

    private fun pow10(exponent: Int): Long {
        var value = 1L
        repeat(exponent) { value *= 10 }
        return value
    }
}
