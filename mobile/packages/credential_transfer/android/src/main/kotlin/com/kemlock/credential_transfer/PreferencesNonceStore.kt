package com.kemlock.credential_transfer

import android.content.Context

/**
 * [NonceStore] in the app's private preferences, one line for each entry: the hash, a tab and the
 * vault id. Only hashes are kept (see [ExportNonces]). A vault id that could break a line is never
 * written.
 */
class PreferencesNonceStore(context: Context) : NonceStore {
    private val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    override fun read(): Map<String, String> = prefs.getString(KEY, "").orEmpty().lineSequence()
        .mapNotNull { line -> line.split('\t').takeIf { it.size == 2 && it[0].isNotEmpty() && it[1].isNotEmpty() } }
        .associate { it[0] to it[1] }

    override fun write(entries: Map<String, String>) {
        val text = entries.entries.filter { (_, vault) -> VaultIds.valid(vault) }.joinToString("\n") { (hash, vault) -> "$hash\t$vault" }
        prefs.edit().putString(KEY, text).apply()
    }

    private companion object {
        const val FILE = "kemlock_credential_export"
        const val KEY = "entries"
    }
}

/** The ids a vault can have on the phone, which the lines of [PreferencesNonceStore] can hold. */
object VaultIds {
    private val allowed = Regex("[A-Za-z0-9_.:-]{1,128}")

    fun valid(id: String): Boolean = allowed.matches(id)
}
