package com.kemlock.app.passwords

import android.content.Context
import java.security.MessageDigest

/**
 * The passwords "Suggest a strong password" filled lately, so a login saved with one is marked as
 * generated. Kept on this phone for half an hour as SHA-256 digests, never the passwords: a
 * generated password is too long and random to be found from its digest.
 */
object GeneratedPasswords {
    private const val PREFERENCES = "kemlock_generated_passwords"
    private const val KEEP_MS = 30 * 60 * 1000L

    fun remember(context: Context, password: String, now: Long = System.currentTimeMillis()) {
        val prefs = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val edit = prefs.edit()
        for ((key, value) in prefs.all) if ((value as? Long ?: 0L) < now - KEEP_MS) edit.remove(key)
        edit.putLong(digest(password), now).apply()
    }

    fun wasGenerated(context: Context, password: String, now: Long = System.currentTimeMillis()): Boolean =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getLong(digest(password), 0L) >= now - KEEP_MS

    private fun digest(password: String): String =
        MessageDigest.getInstance("SHA-256").digest(password.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
}
