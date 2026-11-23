package com.kemlock.app.passwords

import android.os.Build
import androidx.annotation.RequiresApi
import com.kemlock.app.passkeys.B64
import com.kemlock.app.passkeys.Inbox
import com.kemlock.app.passkeys.Json
import com.kemlock.app.passkeys.P256
import java.security.PrivateKey
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** The app a login was saved in: its package and the SHA-256 of its original signing certificate, in hex. */
data class InboxApp(val packageName: String, val cert: String)

/**
 * What waits in a vault's inbox for the app (lib/features/logins/login_inbox.dart's
 * `LoginInboxRecord`): a login saved or updated after a form was sent, or a password generated
 * and filled, kept even if no save follows. [at] is epoch milliseconds.
 */
sealed class LoginRecord {
    abstract val password: String
    abstract val site: String?
    abstract val at: Long

    /** The record's JSON, keys in the order and bytes Dart's `toJson` gives. */
    abstract fun toJson(): String

    /** A login saved by the phone, with the [id] it takes in the vault so a pick remembered for it finds it. */
    class Saved(
        val id: String,
        val name: String,
        val username: String?,
        override val password: String,
        override val site: String?,
        val app: InboxApp?,
        /** Its password was one Kemlock generated. */
        val generated: Boolean,
        override val at: Long,
    ) : LoginRecord() {
        override fun toJson(): String = Json.write(
            linkedMapOf(
                "kind" to "login",
                "id" to id,
                "name" to name,
                "username" to username,
                "password" to password,
                "site" to site,
                "app" to app?.let { linkedMapOf("package" to it.packageName, "cert" to it.cert) },
                "generated" to generated,
                "at" to at,
            ),
        )

        // Never the password, should a record end up in a log.
        override fun toString() = "LoginRecord.Saved($id, $name)"
    }

    /** A password generated and filled for [site], which no save may follow. */
    class Generated(override val password: String, override val site: String?, override val at: Long) : LoginRecord() {
        override fun toJson(): String = Json.write(linkedMapOf("kind" to "generated", "password" to password, "site" to site, "at" to at))

        override fun toString() = "LoginRecord.Generated($site, $at)"
    }
}

/**
 * The login files of a vault's inbox, beside its passkey files, sealed to the same inbox key with
 * another HKDF info so the two kinds never share a key (openspec: add-passwords, design decision 9):
 *
 * ```text
 * {"v": 1, "kind": "login", "epk": base64(ephemeral public point, 65 bytes),
 *  "nonce": base64(12 bytes), "ct": base64(AES-256-GCM ciphertext || tag)}
 * key = HKDF-SHA-256(ikm = ECDH(ephemeral, inbox key), salt = epk || inbox public point,
 *                    info = "kemlock-login-inbox-v1", 32 bytes)
 * plaintext = the record's JSON, see [LoginRecord]
 * ```
 *
 * The outer `kind` lets the app pick the info before opening a file; a version of the app from
 * before logins tries it as a passkey, fails, and leaves it.
 */
@RequiresApi(Build.VERSION_CODES.O)
object LoginInbox {
    const val INFO = "kemlock-login-inbox-v1"
    const val KIND = "login"
    private const val VERSION = 1

    private val random = SecureRandom()

    /** A new file's name, `login-<uuid>.json`. */
    fun fileName(): String = "login-${UUID.randomUUID()}.json"

    /**
     * [record] sealed to the inbox key whose public point is [recipient], as the inbox file's JSON.
     * The ephemeral key (its private half and point) and the nonce are fresh unless given, as the
     * fixtures give them.
     */
    fun seal(record: LoginRecord, recipient: ByteArray, ephemeral: Pair<PrivateKey, ByteArray>? = null, nonce: ByteArray? = null): String {
        val (ephemeralKey, epk) = ephemeral ?: P256.newKeyPair().let { it.private to P256.point(it.public) }
        val iv = nonce ?: ByteArray(12).also(random::nextBytes)
        require(iv.size == 12) { "The nonce is 12 bytes" }
        val key = Inbox.hkdf(P256.sharedSecret(ephemeralKey, recipient), salt = epk + recipient, info = INFO.toByteArray(Charsets.UTF_8))
        val ct = try {
            Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
                doFinal(record.toJson().toByteArray(Charsets.UTF_8))
            }
        } finally {
            key.fill(0)
        }
        return Json.write(linkedMapOf("v" to VERSION, "kind" to KIND, "epk" to B64.encode(epk), "nonce" to B64.encode(iv), "ct" to B64.encode(ct)))
    }
}
