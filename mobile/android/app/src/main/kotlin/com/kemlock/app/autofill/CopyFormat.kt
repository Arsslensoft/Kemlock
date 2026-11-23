package com.kemlock.app.autofill

import android.os.Build
import androidx.annotation.RequiresApi
import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64

// What the app hands the autofill side (lib/features/autofill/autofill_copy.dart), and the
// picks the fill screen remembers. Kept free of Android classes but org.json, so the JVM
// tests read the same fixture as the Dart tests.

/** The only version of the copy, the index and the picks this code reads. */
const val FORMAT_VERSION = 1

/** A copy, index or pick of another version: the app writes it again when opened. */
class UnsupportedFormatException(message: String) : Exception(message)

enum class Kind { TOTP, STEAM }

/** One account of a vault's copy, with its secret already decoded by the app. */
class CopyAccount(
    val vault: String,
    val id: String,
    val issuer: String,
    val label: String,
    val kind: Kind,
    val algorithm: String,
    val digits: Int,
    val period: Int,
    val key: ByteArray,
    val domains: List<String>,
) {
    /** The name the fill screen shows: the issuer, else the label. */
    val name: String get() = issuer.ifEmpty { label }
}

/** One account of a vault's index: what suggestions show before biometrics. */
data class IndexAccount(val vault: String, val id: String, val issuer: String, val domains: List<String>)

/**
 * One passkey of a vault's copy, with its [privateKey] (PKCS#8 DER, base64), or of its index,
 * without. [credentialId] and [userHandle] are base64url without padding.
 */
class PasskeyEntry(
    val vault: String,
    val credentialId: String,
    val rpId: String,
    val rpName: String?,
    val userHandle: String,
    val userName: String,
    val userDisplayName: String?,
    val privateKey: String? = null,
) {
    /** The name the phone shows for it: the user name, else the display name, else the site. */
    val name: String get() = userName.ifEmpty { userDisplayName ?: rpId }

    // Never the key, should an entry end up in a log.
    override fun toString() = "PasskeyEntry($vault, $credentialId, $rpId, $userName)"
}

/**
 * One login of a vault's copy, with its [password], or of its index, without (`AutofillLogin` in
 * autofill_copy.dart). [domains] are registrable domains, or exact hosts marked `=`; a login
 * saved in an app has none.
 */
class LoginEntry(
    val vault: String,
    val id: String,
    val name: String,
    val username: String?,
    val domains: List<String>,
    val password: String? = null,
) {
    // Never the password, should an entry end up in a log.
    override fun toString() = "LoginEntry($vault, $id, $name)"
}

/**
 * What the app lets the phone do with a vault besides filling it (`VaultTakes` in
 * lib/platform/autofill.dart): save the passkeys sites make, save the logins forms send, and
 * suggest strong passwords. A vault written before passwords has none kept, and its inbox key
 * then means passkeys alone.
 */
data class VaultTakes(val passkeys: Boolean = false, val logins: Boolean = false, val suggest: Boolean = false) {
    fun toJson(): String =
        JSONObject().put("v", FORMAT_VERSION).put("passkeys", passkeys).put("logins", logins).put("suggest", suggest).toString()

    companion object {
        /** What the app sent over the channel; null when it sent nothing, as an app from before passwords. */
        fun fromMap(map: Map<*, *>?): VaultTakes? = map?.let {
            VaultTakes(passkeys = it["passkeys"] == true, logins = it["logins"] == true, suggest = it["suggest"] == true)
        }

        /** A file [toJson] wrote, or null for one of another version. */
        fun parse(json: String): VaultTakes? = try {
            val o = JSONObject(json)
            if (o.optInt("v") != FORMAT_VERSION) null
            else VaultTakes(o.optBoolean("passkeys"), o.optBoolean("logins"), o.optBoolean("suggest"))
        } catch (_: org.json.JSONException) {
            null
        }
    }
}

/** Where a code is filled: a website's host, or an app with the digest of its signing certificate. */
sealed class Target {
    data class Web(val host: String) : Target() {
        override fun toString() = "web:$host"
    }

    data class App(val packageName: String, val certificate: String) : Target() {
        override fun toString() = "app:$packageName:$certificate"
    }

    companion object {
        fun web(host: String): Web = Web(host.lowercase().trimEnd('.'))

        /** The target [text] names, as [toString] wrote it, or null. */
        fun parse(text: String): Target? = when {
            text.startsWith("web:") -> text.removePrefix("web:").takeIf { it.isNotEmpty() }?.let(::Web)
            text.startsWith("app:") -> {
                val rest = text.removePrefix("app:")
                val colon = rest.lastIndexOf(':')
                if (colon <= 0 || colon == rest.length - 1) null else App(rest.substring(0, colon), rest.substring(colon + 1))
            }
            else -> null
        }
    }
}

/** The person picked [account] of [vault] for [target], and asked to be offered it there again. */
data class Pick(val vault: String, val target: Target, val account: String) {
    fun toJson(): String = JSONObject().put("v", FORMAT_VERSION).put("target", target.toString()).put("account", account).toString()

    companion object {
        /** A pick as [toJson] wrote it, or null for one this version can't read. */
        fun parse(vault: String, json: String): Pick? = try {
            val o = JSONObject(json)
            val target = Target.parse(o.optString("target"))
            if (o.optInt("v") != FORMAT_VERSION || target == null || o.optString("account").isEmpty()) null
            else Pick(vault, target, o.getString("account"))
        } catch (_: org.json.JSONException) {
            null
        }
    }
}

object CopyFormat {
    /** The accounts of a vault's copy. Throws [UnsupportedFormatException] for another version. */
    @RequiresApi(Build.VERSION_CODES.O)
    fun parseCopy(json: String): List<CopyAccount> {
        val root = JSONObject(json)
        checkVersion(root)
        val vault = root.getString("vault")
        return root.getJSONArray("accounts").objects().mapNotNull { a ->
            val kind = when (a.getString("kind")) {
                "totp" -> Kind.TOTP
                "steam" -> Kind.STEAM
                else -> return@mapNotNull null
            }
            CopyAccount(
                vault = vault,
                id = a.getString("id"),
                issuer = a.optString("issuer"),
                label = a.optString("label"),
                kind = kind,
                algorithm = a.getString("algorithm"),
                digits = a.getInt("digits"),
                period = a.getInt("period"),
                key = Base64.getDecoder().decode(a.getString("key")),
                domains = a.optJSONArray("domains")?.strings().orEmpty(),
            )
        }
    }

    /**
     * Whether a vault's copy holds codes to fill. One written while only the vault's passkeys or logins are
     * on holds none, and offers no code. A copy this version can't read is taken to hold some, so
     * the fill screen can say to open the app.
     */
    @RequiresApi(Build.VERSION_CODES.O)
    fun fillsCodes(copy: String): Boolean = try {
        parseCopy(copy).isNotEmpty()
    } catch (_: Exception) {
        true
    }

    /** The accounts of a vault's index. Throws [UnsupportedFormatException] for another version. */
    fun parseIndex(json: String): List<IndexAccount> {
        val root = JSONObject(json)
        checkVersion(root)
        val vault = root.getString("vault")
        return root.getJSONArray("accounts").objects().map { a ->
            IndexAccount(vault, a.getString("id"), a.optString("issuer"), a.optJSONArray("domains")?.strings().orEmpty())
        }
    }

    /**
     * The passkeys of a vault's copy, with their keys, or of its index, without
     * (`autofillPasskey` in autofill_copy.dart). A copy or index without `passkeys` holds none,
     * as every one written before passkeys. Throws [UnsupportedFormatException] for another version.
     */
    fun parsePasskeys(json: String): List<PasskeyEntry> {
        val root = JSONObject(json)
        checkVersion(root)
        val vault = root.getString("vault")
        return root.optJSONArray("passkeys")?.objects().orEmpty().mapNotNull { p ->
            fun optional(key: String): String? = (p.opt(key) as? String)?.ifEmpty { null }
            PasskeyEntry(
                vault = vault,
                credentialId = optional("credentialId") ?: return@mapNotNull null,
                rpId = optional("rpId") ?: return@mapNotNull null,
                rpName = optional("rpName"),
                userHandle = optional("userHandle") ?: return@mapNotNull null,
                userName = optional("userName").orEmpty(),
                userDisplayName = optional("userDisplayName"),
                privateKey = optional("privateKey"),
            )
        }
    }

    /**
     * The logins of a vault's copy, with their passwords, or of its index, without (`AutofillLogin`
     * in autofill_copy.dart). A copy or index without `logins` holds none, as every one written
     * before passwords; an entry without its id or domains is left out rather than the whole copy.
     * Throws [UnsupportedFormatException] for another version.
     */
    fun parseLogins(json: String): List<LoginEntry> {
        val root = JSONObject(json)
        checkVersion(root)
        val vault = root.getString("vault")
        return root.optJSONArray("logins")?.objects().orEmpty().mapNotNull { l ->
            fun optional(key: String): String? = (l.opt(key) as? String)?.ifEmpty { null }
            LoginEntry(
                vault = vault,
                id = optional("id") ?: return@mapNotNull null,
                name = optional("name").orEmpty(),
                username = optional("username"),
                domains = (l.opt("domains") as? JSONArray)?.strings() ?: return@mapNotNull null,
                password = optional("password"),
            )
        }
    }

    /** Whether a vault's index holds logins, as it does while its passwords are on; one this version can't read holds none. */
    fun holdsLogins(index: String): Boolean = try {
        parseLogins(index).isNotEmpty()
    } catch (_: Exception) {
        false
    }

    /**
     * Whether a vault's index names its accounts, as it does while the vault names services in
     * suggestions. An index written for passkeys alone names none, and the vault's picks then stay
     * sealed. An index this version can't read names none.
     */
    fun namesAccounts(index: String): Boolean = try {
        parseIndex(index).isNotEmpty()
    } catch (_: Exception) {
        false
    }

    /** The picks of a vault's plain picks file, which is kept only while the vault names services. */
    fun parsePlainPicks(vault: String, json: String): List<Pick> {
        val root = JSONObject(json)
        checkVersion(root)
        return root.getJSONArray("picks").objects().mapNotNull { Pick.parse(vault, it.toString()) }
    }

    fun plainPicks(picks: List<Pick>): String =
        JSONObject().put("v", FORMAT_VERSION).put("picks", JSONArray(picks.map { JSONObject(it.toJson()) })).toString()

    private fun checkVersion(root: JSONObject) {
        val v = root.optInt("v", -1)
        if (v != FORMAT_VERSION) throw UnsupportedFormatException("Format $v isn't $FORMAT_VERSION")
    }

    private fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }

    private fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }
}
