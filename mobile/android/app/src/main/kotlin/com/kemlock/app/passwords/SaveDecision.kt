package com.kemlock.app.passwords

import com.kemlock.app.autofill.FieldNode
import com.kemlock.app.autofill.LoginEntry
import com.kemlock.app.autofill.Matching
import com.kemlock.app.autofill.Pick
import com.kemlock.app.autofill.Target

/** The login fields a fill request found, which the save request reads back once the form is sent. */
data class SaveFields<T>(val username: T?, val password: T?, val newPasswords: List<T>)

/**
 * What a sent form saves (openspec: add-passwords, the password-autofill spec): the password, new
 * or current, and the username typed, as a login of the vault the prompt named. A login of that
 * vault for the same site or app and username is updated, keeping its id so the app takes the new
 * password in as a change; any other is new, named after the site, or after the app with no
 * website. Free of Android classes, so the JVM tests feed it hand-built structures.
 */
object SaveDecision {
    class Result(val record: LoginRecord.Saved, val update: Boolean)

    /**
     * The login to save from the [roots] of the form as it was sent, or null when no password was
     * typed. [appLabel] names a login saved in an app; [generated] says a password was one Kemlock
     * suggested; [newId] gives a new login its id.
     */
    fun <T> decide(
        roots: List<FieldNode<T>>,
        fields: SaveFields<T>,
        target: Target,
        vault: String,
        logins: List<LoginEntry>,
        picks: List<Pick>,
        appLabel: String,
        at: Long,
        generated: (String) -> Boolean,
        newId: () -> String,
    ): Result? {
        val values = valuesOf(roots)
        val password = fields.newPasswords.firstNotNullOfOrNull { values[it]?.takeIf(String::isNotEmpty) }
            ?: fields.password?.let { values[it] }?.takeIf(String::isNotEmpty)
            ?: return null
        val username = fields.username?.let { values[it] }?.trim()?.takeIf(String::isNotEmpty)
        val existing = existing(target, vault, username, logins, picks)
        val site = (target as? Target.Web)?.host
        val name = existing?.name ?: site?.removePrefix("www.") ?: appLabel
        val app = (target as? Target.App)?.let { InboxApp(it.packageName, it.certificate) }
        val record = LoginRecord.Saved(existing?.id ?: newId(), name, username, password, site, app, generated(password), at)
        return Result(record, existing != null)
    }

    /** [vault]'s login for [target] whose username is [username], whatever its case; null when it has none. */
    fun existing(target: Target, vault: String, username: String?, logins: List<LoginEntry>, picks: List<Pick>): LoginEntry? {
        val wanted = username?.trim()?.lowercase()?.takeIf(String::isNotEmpty)
        return Matching.matching(target, logins.filter { it.vault == vault }, picks, { it.vault }, { it.id }, { it.domains })
            .firstOrNull { it.username?.trim()?.lowercase()?.takeIf(String::isNotEmpty) == wanted }
    }

    /** The usernames of [vault]'s logins for [target], which a sent form updates rather than adds to. */
    fun knownUsernames(target: Target, vault: String, logins: List<LoginEntry>, picks: List<Pick>): List<String> =
        Matching.matching(target, logins.filter { it.vault == vault }, picks, { it.vault }, { it.id }, { it.domains })
            .mapNotNull { it.username?.trim()?.takeIf(String::isNotEmpty) }.distinct()

    /** Each text field's value under [roots], by its id. */
    private fun <T> valuesOf(roots: List<FieldNode<T>>): Map<T, String> {
        val values = HashMap<T, String>()
        fun visit(node: FieldNode<T>) {
            val id = node.id
            val value = node.value
            if (id != null && value != null) values[id] = value
            node.children.forEach(::visit)
        }
        roots.forEach(::visit)
        return values
    }
}
