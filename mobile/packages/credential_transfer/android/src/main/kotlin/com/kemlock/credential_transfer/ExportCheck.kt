package com.kemlock.credential_transfer

import android.content.pm.ApplicationInfo

/** Why an export request was turned away. Never told to the other app: it gets a cancel. */
enum class ExportRefusal {
    /** Not started by the system's selector, or started by another app: the immediate caller is wrong. */
    UNTRUSTED_CALLER,

    /** The id of the entry isn't one Kemlock registered: the person didn't pick Kemlock there. */
    UNKNOWN_ENTRY,
}

sealed class ExportVerdict {
    /** The request is the system's, for the entry of [vaultId]. */
    data class Allowed(val vaultId: String) : ExportVerdict()

    data class Refused(val reason: ExportRefusal) : ExportVerdict()
}

/**
 * The two checks the exported activity makes before it does anything else, and before any Dart is
 * called (openspec: plan add-credential-exchange, task 8.4), written without Android's services so
 * that JVM tests can try each: the activity is exported, so any app can start it, and the secret
 * ids and the caller are what tell the system's pick from a forged start.
 *
 * 1. The immediate caller, `Activity.getCallingPackage()`, must be the system's credential
 *    selector, and that package must be a system app. The selector starts the activity for a
 *    result, so a start by anything else, which has no calling package, or another app's, is
 *    turned away. A package name alone proves nothing: on a phone without Play services any app
 *    can be installed under `com.google.android.gms`, so the package must also be part of the
 *    system image ([isSystemApp]), as Play services is, updated or not.
 * 2. The entry's secret id must be one Kemlock registered ([ExportNonces]). An app can't guess it.
 *
 * And the URI the export is written to must not be one of Kemlock's own providers ([targetAllowed]).
 * The manifest's `requireContentUriPermissionFromCaller` makes the system check that the caller can
 * write the URI, but only from Android 15 (API 35), so this check is the only one before that.
 */
object ExportCheck {
    /** The selector of Credential Manager's transfer, on phones with Google Play services. */
    val TRUSTED_SELECTORS = setOf("com.google.android.gms")

    /**
     * Whether an app whose `ApplicationInfo.flags` are [flags] is part of the system image: a system app, or
     * a system app that has had an update installed over it (which is what Play services usually is).
     */
    fun isSystemApp(flags: Int): Boolean = flags and (ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0

    /**
     * Whether [callingPackage] is the system's selector: a package in [trusted] that [systemApp] says is a
     * system app. [systemApp] answers false for a package it can't look up. Looks at nothing else.
     */
    fun callerTrusted(callingPackage: String?, systemApp: (String) -> Boolean, trusted: Set<String> = TRUSTED_SELECTORS): Boolean =
        callingPackage != null && callingPackage in trusted && systemApp(callingPackage)

    /**
     * Whether the content URI an export request gives to write to may be written: it must be a `content`
     * URI, with an authority, that is not one of [ownAuthorities], the content providers of Kemlock itself.
     * The importer names the URI, so a request for Kemlock's own provider would have Kemlock write the
     * export into a file of its own. A user id before an `@` (`content://10@authority/..`) and a port are
     * left out of the comparison, and case doesn't matter, so no spelling slips past.
     */
    fun targetAllowed(scheme: String?, authority: String?, ownAuthorities: Set<String>): Boolean {
        if (scheme == null || !scheme.equals("content", ignoreCase = true)) return false
        val name = authority?.substringAfterLast('@')?.substringBefore(':')?.lowercase()
        if (name.isNullOrEmpty()) return false
        return ownAuthorities.none { it.lowercase() == name }
    }

    fun verdict(
        callingPackage: String?,
        credId: String?,
        nonces: ExportNonces,
        systemApp: (String) -> Boolean,
        trusted: Set<String> = TRUSTED_SELECTORS,
    ): ExportVerdict {
        if (!callerTrusted(callingPackage, systemApp, trusted)) return ExportVerdict.Refused(ExportRefusal.UNTRUSTED_CALLER)
        val vault = nonces.vaultOf(credId) ?: return ExportVerdict.Refused(ExportRefusal.UNKNOWN_ENTRY)
        return ExportVerdict.Allowed(vault)
    }
}
