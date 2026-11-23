package com.kemlock.app.passwords

import android.content.Context
import org.json.JSONObject

/**
 * The password rules of known sites, from Apple's password-manager-resources
 * (`assets/password-manager-resources/password-rules.json`, MIT, its licence beside it; refreshed
 * by `tool/autofill/update_password_rules.sh`). A site is keyed by its registrable domain, or a
 * host under it whose rules differ, so a host takes the rules of the nearest name at or above it.
 */
class SiteRules(private val rules: Map<String, String>) {
    /** The rules for [host], or null when the list names neither it nor a domain above it. */
    fun rulesFor(host: String?): PasswordRules? = textFor(host)?.let(PasswordRules::parse)

    /** The rules for [host] as the list writes them, or null when it names neither it nor a domain above it. */
    fun textFor(host: String?): String? {
        var name = host?.trim()?.trimEnd('.')?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        while (true) {
            rules[name]?.let { return it }
            val dot = name.indexOf('.')
            if (dot < 0) return null
            name = name.substring(dot + 1)
        }
    }

    companion object {
        const val ASSET = "password-manager-resources/password-rules.json"

        /** Reads the list's JSON: `{"<domain>": {"password-rules": "…"}}`; an entry without rules is skipped. */
        fun parse(json: String): SiteRules {
            val root = JSONObject(json)
            val rules = HashMap<String, String>()
            for (domain in root.keys()) {
                val text = root.optJSONObject(domain)?.optString("password-rules").orEmpty()
                if (text.isNotBlank()) rules[domain.lowercase()] = text
            }
            return SiteRules(rules)
        }

        @Volatile private var bundled: SiteRules? = null

        /** The bundled list, read once; an empty one if it can't be read, so passwords follow the choices alone. */
        fun bundled(context: Context): SiteRules = bundled ?: synchronized(this) {
            bundled ?: runCatching {
                parse(context.assets.open(ASSET).bufferedReader().use { it.readText() })
            }.getOrDefault(SiteRules(emptyMap())).also { bundled = it }
        }
    }
}
