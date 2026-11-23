package com.kemlock.app.passkeys

import android.os.Build
import androidx.annotation.RequiresApi
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.PrivateKey
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** base64 as the app writes it: standard with padding for keys and points, url-safe without for WebAuthn ids. */
@RequiresApi(Build.VERSION_CODES.O)
object B64 {
    fun encode(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    fun decode(text: String): ByteArray = Base64.getDecoder().decode(text)

    fun url(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    /** base64url, with or without padding, as sites write their ids and challenges. */
    fun fromUrl(text: String): ByteArray = Base64.getUrlDecoder().decode(text.trimEnd('='))
}

/**
 * A passkey as the provider seals it (lib/features/passkeys/passkey_inbox.dart's `InboxRecord`):
 * what the site registered, and its key. [credentialId] and [userHandle] are base64url without
 * padding, [privateKey] PKCS#8 DER in base64, [createdAt] epoch milliseconds.
 */
@RequiresApi(Build.VERSION_CODES.O)
class InboxRecord(
    val credentialId: String,
    val rpId: String,
    val rpName: String?,
    val userHandle: String,
    val userName: String,
    val userDisplayName: String?,
    val privateKey: String,
    val createdAt: Long,
) {
    /** The record's JSON, keys in the order and bytes Dart's `toJson` gives. */
    fun toJson(): String = Json.write(
        linkedMapOf(
            "credentialId" to credentialId,
            "rpId" to rpId,
            "rpName" to rpName,
            "userHandle" to userHandle,
            "userName" to userName,
            "userDisplayName" to userDisplayName,
            "privateKey" to privateKey,
            "createdAt" to createdAt,
        ),
    )

    // Never the key, should a record end up in a log.
    override fun toString() = "InboxRecord($credentialId, $rpId, $userName)"

    companion object {
        /** A record as [toJson] or the app wrote it; throws for one without its ids or key. */
        fun parse(json: String): InboxRecord {
            val o = JSONObject(json)
            fun text(key: String): String = o.optString(key).ifEmpty { throw IllegalArgumentException("No $key") }
            fun optional(key: String): String? = (o.opt(key) as? String)?.ifEmpty { null }
            return InboxRecord(
                credentialId = text("credentialId"),
                rpId = text("rpId"),
                rpName = optional("rpName"),
                userHandle = text("userHandle"),
                userName = optional("userName").orEmpty(),
                userDisplayName = optional("userDisplayName"),
                privateKey = text("privateKey"),
                createdAt = o.optLong("createdAt"),
            )
        }
    }
}

/**
 * The inbox a passkey made while its vault is locked waits in, until the app opens it with the
 * vault's inbox key (lib/features/passkeys/passkey_inbox.dart). One file per passkey:
 *
 * ```text
 * {"v": 1, "epk": base64(ephemeral public point, 65 bytes),
 *  "nonce": base64(12 bytes), "ct": base64(AES-256-GCM ciphertext || tag)}
 * key = HKDF-SHA-256(ikm = ECDH(ephemeral, inbox key), salt = epk || inbox public point,
 *                    info = "kemlock-passkey-inbox-v1", 32 bytes)
 * plaintext = the record's JSON, see [InboxRecord]
 * ```
 */
@RequiresApi(Build.VERSION_CODES.O)
object Inbox {
    const val INFO = "kemlock-passkey-inbox-v1"
    const val VERSION = 1

    private val random = SecureRandom()

    /** HKDF-SHA-256 (RFC 5869) of [ikm]. */
    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int = 32): ByteArray {
        val prk = hmac(salt, ikm)
        val out = ByteArrayOutputStream()
        var block = ByteArray(0)
        var i = 1
        while (out.size() < length) {
            block = hmac(prk, block + info + byteArrayOf(i.toByte()))
            out.write(block)
            i++
        }
        return out.toByteArray().copyOf(length)
    }

    /** The AES key of an inbox file whose ephemeral point is [epk], for the inbox key at [recipient]. */
    fun fileKey(shared: ByteArray, epk: ByteArray, recipient: ByteArray): ByteArray =
        hkdf(shared, salt = epk + recipient, info = INFO.toByteArray(Charsets.UTF_8))

    /**
     * [record] sealed to the inbox key whose public point is [recipient], as the inbox file's JSON.
     * The ephemeral key (its private half and point) and the nonce are fresh unless given, as the
     * fixtures give them.
     */
    fun seal(record: InboxRecord, recipient: ByteArray, ephemeral: Pair<PrivateKey, ByteArray>? = null, nonce: ByteArray? = null): String {
        val (ephemeralKey, epk) = ephemeral ?: P256.newKeyPair().let { it.private to P256.point(it.public) }
        val iv = nonce ?: ByteArray(12).also(random::nextBytes)
        require(iv.size == 12) { "The nonce is 12 bytes" }
        val key = fileKey(P256.sharedSecret(ephemeralKey, recipient), epk, recipient)
        val ct = try {
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
                doFinal(record.toJson().toByteArray(Charsets.UTF_8))
            }
        } finally {
            key.fill(0)
        }
        return Json.write(linkedMapOf("v" to VERSION, "epk" to B64.encode(epk), "nonce" to B64.encode(iv), "ct" to B64.encode(ct)))
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run {
        // RFC 5869: no salt is a hash length of zeros, which HMAC gives an empty key anyway
        init(SecretKeySpec(if (key.isEmpty()) ByteArray(32) else key, "HmacSHA256"))
        doFinal(data)
    }
}
