package com.kemlock.app.passwords

import android.content.Context
import android.os.Build
import androidx.annotation.RequiresApi
import com.kemlock.app.R
import com.kemlock.app.autofill.AutofillStore
import com.kemlock.app.passkeys.PasskeyMatching
import com.kemlock.app.passkeys.PasskeyStore

/**
 * The vaults that save logins on this phone (openspec: add-passwords, the password-autofill spec):
 * those with an inbox key whose app said to take logins, the one whose copy the app wrote last
 * (which it does each time the vault is opened) first. A login saved, or a password generated,
 * goes to the first.
 */
@RequiresApi(Build.VERSION_CODES.O)
object SavingVaults {
    /** The app's key-value store, where each vault's config holds its name. */
    private const val APP_PREFERENCES = "CapacitorStorage"

    /** [vaults] that save logins, by [takesLogins] and [hasInboxKey], the one written last first. */
    fun ordered(vaults: List<String>, takesLogins: (String) -> Boolean, hasInboxKey: (String) -> Boolean, lastWritten: (String) -> Long?): List<String> =
        PasskeyMatching.byLastUse(vaults.filter { takesLogins(it) && hasInboxKey(it) }, lastWritten)

    fun ordered(context: Context): List<String> {
        val autofill = AutofillStore(context)
        val inbox = PasskeyStore(context)
        return ordered(inbox.vaults(), autofill::takesLogins, { inbox.inboxKey(it) != null }, autofill::lastWritten)
    }

    /** The name [vault] has in the app, or the one a vault has before it is named. */
    fun name(context: Context, vault: String): String =
        PasskeyMatching.vaultName(context.getSharedPreferences(APP_PREFERENCES, Context.MODE_PRIVATE).getString(PasskeyMatching.configKey(vault), null))
            ?: context.getString(R.string.passkeys_vault_default)
}
