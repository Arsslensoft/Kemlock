package com.kemlock.app.passkeys

import android.os.Build
import androidx.annotation.RequiresApi
import com.kemlock.app.autofill.PasskeyEntry
import org.json.JSONObject

/** What the provider offers for a request, worked out from the indexes before any biometrics. */
@RequiresApi(Build.VERSION_CODES.O)
object PasskeyMatching {
    /**
     * The passkeys of [entries] for exactly [rpId], never a subdomain or a parent of it, that
     * [allowed] takes when it names any, each credential once: a passkey the provider made that
     * the app has since taken in is in both the index and the provider's records.
     */
    fun matching(rpId: String, allowed: List<ByteArray>, entries: List<PasskeyEntry>): List<PasskeyEntry> {
        val rp = rpId.lowercase().trimEnd('.')
        val seen = HashSet<String>()
        return entries.filter { entry ->
            val id = try {
                B64.fromUrl(entry.credentialId)
            } catch (_: IllegalArgumentException) {
                return@filter false
            }
            entry.rpId.lowercase().trimEnd('.') == rp &&
                (allowed.isEmpty() || allowed.any { it.contentEquals(id) }) &&
                seen.add(B64.url(id))
        }
    }

    /** [vaults], the one used last first: by when the app last wrote its copy, then by id. */
    fun byLastUse(vaults: List<String>, lastUsed: (String) -> Long?): List<String> =
        vaults.sortedWith(compareByDescending<String> { lastUsed(it) ?: Long.MIN_VALUE }.thenBy { it })

    /** The storage key of [vault]'s config, as vault_registry.dart names it. */
    fun configKey(vault: String): String = if (vault == "main") "backmycodes_vault_config" else "backmycodes_vault_config::$vault"

    /** The name a vault's [config] gives it (vault_registry.dart's `vaultName`), or null for none. */
    fun vaultName(config: String?): String? = try {
        (JSONObject(config ?: return null).opt("name") as? String)?.takeIf { it.isNotBlank() }
    } catch (_: org.json.JSONException) {
        null
    }
}
