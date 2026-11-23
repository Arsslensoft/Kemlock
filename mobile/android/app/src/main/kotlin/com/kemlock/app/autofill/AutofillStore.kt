package com.kemlock.app.autofill

import android.content.Context
import android.os.Build
import androidx.annotation.RequiresApi
import java.io.File

/**
 * The files autofill reads, in `noBackupFilesDir/autofill`, out of Android's backups: the key
 * they're sealed to stays on this phone, so a restored copy could never be opened.
 *
 * For each vault:
 * - `<vault>.copy`: the copy the app wrote, sealed to [AutofillKey].
 * - `<vault>.index.json`: ids, issuers and domains, in the clear, while the vault names services in suggestions.
 * - `<vault>.picks`: the remembered picks, one sealed line each, appended without opening the others.
 * - `<vault>.picks.json`: the same picks in the clear, for suggestions: a code's only beside an index that names
 *   accounts, a login's beside one that holds the logins.
 * - `<vault>.nocodes`: empty, beside a copy that holds passkeys and no codes.
 * - `<vault>.takes.json`: what the app lets the phone do with the vault besides filling it
 *   ([VaultTakes]): save passkeys, save logins, suggest passwords. A vault written before passwords
 *   has none, and its inbox key means passkeys alone.
 *
 * While a vault's passkeys are on, its copy and index hold them too, and `created/<vault>` the
 * passkeys the provider made since ([com.kemlock.app.passkeys.PasskeyStore]); while its passwords
 * are on, its logins, with their passwords in the copy alone.
 */
@RequiresApi(Build.VERSION_CODES.O)
class AutofillStore(context: Context) {
    private val dir = File(context.noBackupFilesDir, "autofill")

    private fun file(vault: String, suffix: String): File {
        require(validVault.matches(vault)) { "Not a vault id: $vault" }
        return File(dir, "$vault$suffix")
    }

    /** The vaults that have a copy. */
    fun vaults(): List<String> = dir.listFiles()?.map { it.name }?.filter { it.endsWith(COPY) }?.map { it.removeSuffix(COPY) }?.sorted().orEmpty()

    fun hasCopies(): Boolean = vaults().isNotEmpty()

    /** Whether any vault's copy has codes to fill: not one written for its passkeys or logins alone. */
    fun fillsCodes(): Boolean = vaults().any { !file(it, NO_CODES).exists() }

    /** Whether any vault fills passwords: its index holds its logins while its passwords are on. */
    fun fillsLogins(): Boolean = vaults().any { vault ->
        val index = file(vault, INDEX)
        index.exists() && CopyFormat.holdsLogins(index.readText())
    }

    /** What the app lets the phone do with [vault]; null for a vault written before passwords, or with no copy. */
    fun takes(vault: String): VaultTakes? = file(vault, TAKES).takeIf { it.exists() }?.let { VaultTakes.parse(it.readText()) }

    /**
     * Whether the phone may save [vault]'s passkeys, given it has an inbox key: as the app said,
     * or, for a vault written before passwords, always, since its inbox key meant passkeys alone.
     */
    fun takesPasskeys(vault: String): Boolean = takes(vault)?.passkeys ?: true

    /** Whether the phone may save the logins forms send to [vault], given it has an inbox key. */
    fun takesLogins(vault: String): Boolean = takes(vault)?.logins ?: false

    /** Whether a strong password is suggested on [vault]'s sign-up forms. */
    fun suggestsPasswords(vault: String): Boolean = takes(vault)?.suggest ?: false

    /** When the app last wrote [vault]'s copy, which it does each time the vault is opened, or null for none. */
    fun lastWritten(vault: String): Long? = file(vault, COPY).takeIf { it.exists() }?.lastModified()

    /**
     * Seals [copy] to the key, making the key first, and writes it with [index], or removes the
     * index, and with [takes], or removes them for an app that sent none.
     */
    fun writeVault(vault: String, copy: String, index: String?, takes: VaultTakes? = null) {
        if (!AutofillKey.isValid()) {
            // A key biometrics changed under opens nothing written before: start again
            removeAll()
            AutofillKey.create()
        }
        dir.mkdirs()
        writeAtomically(file(vault, COPY), AutofillKey.seal(copy.toByteArray()))
        // Marks a copy for passkeys alone, which the code service leaves out; one from before passkeys has no mark
        val noCodes = file(vault, NO_CODES)
        if (CopyFormat.fillsCodes(copy)) noCodes.delete() else noCodes.writeText("")
        if (index == null) {
            file(vault, INDEX).delete()
            file(vault, PLAIN_PICKS).delete()
        } else {
            writeAtomically(file(vault, INDEX), index)
            keepNamedPicks(vault, copy, index)
        }
        if (takes == null) file(vault, TAKES).delete() else writeAtomically(file(vault, TAKES), takes.toJson())
    }

    fun removeVault(vault: String) {
        for (suffix in listOf(COPY, INDEX, PICKS, PLAIN_PICKS, NO_CODES, TAKES)) file(vault, suffix).delete()
    }

    /** Every vault's files and the key. */
    fun removeAll() {
        dir.deleteRecursively()
        AutofillKey.delete()
    }

    /** What suggestions may show before biometrics: the indexes and their plain picks. */
    fun suggestions(): Pair<List<IndexAccount>, List<Pick>> {
        val accounts = mutableListOf<IndexAccount>()
        val picks = mutableListOf<Pick>()
        for (vault in vaults()) {
            val index = file(vault, INDEX)
            if (!index.exists()) continue
            try {
                accounts += CopyFormat.parseIndex(index.readText())
                val plain = file(vault, PLAIN_PICKS)
                if (plain.exists()) picks += CopyFormat.parsePlainPicks(vault, plain.readText())
            } catch (_: Exception) {
                // Another version's index: the app writes it again when opened.
            }
        }
        return accounts to picks
    }

    /** What every vault's copy and picks hold, once opened. */
    class Opened(val accounts: List<CopyAccount>, val logins: List<LoginEntry>, val picks: List<Pick>)

    /** Every vault's copy and picks, opened. Needs biometrics just before; see [AutofillKey.open]. */
    fun open(): Opened {
        val accounts = mutableListOf<CopyAccount>()
        val logins = mutableListOf<LoginEntry>()
        val picks = mutableListOf<Pick>()
        for (vault in vaults()) {
            val copy = String(AutofillKey.open(file(vault, COPY).readText()))
            accounts += CopyFormat.parseCopy(copy)
            logins += CopyFormat.parseLogins(copy)
            val sealed = file(vault, PICKS)
            if (sealed.exists()) {
                sealed.readLines().filter { it.isNotBlank() }.mapNotNullTo(picks) { line ->
                    try {
                        Pick.parse(vault, String(AutofillKey.open(line)))
                    } catch (e: KeyInvalidatedException) {
                        throw e
                    } catch (_: Exception) {
                        null
                    }
                }
            }
        }
        return Opened(accounts, logins, picks)
    }

    /** The passkeys of every vault's index, without keys: what the passkey provider offers before biometrics. */
    fun indexPasskeys(): List<PasskeyEntry> = vaults().flatMap { vault ->
        val index = file(vault, INDEX)
        try {
            if (index.exists()) CopyFormat.parsePasskeys(index.readText()) else emptyList()
        } catch (_: Exception) {
            // Another version's index: the app writes it again when opened.
            emptyList()
        }
    }

    /** The logins of every vault's index, without passwords: what suggestions name before biometrics. */
    fun indexLogins(): List<LoginEntry> = vaults().flatMap { vault ->
        val index = file(vault, INDEX)
        try {
            if (index.exists()) CopyFormat.parseLogins(index.readText()) else emptyList()
        } catch (_: Exception) {
            // Another version's index: the app writes it again when opened.
            emptyList()
        }
    }

    /** The passkeys of [vault]'s copy, with their keys. Needs biometrics just before; see [AutofillKey.open]. */
    fun openPasskeys(vault: String): List<PasskeyEntry> {
        val copy = file(vault, COPY)
        if (!copy.exists()) return emptyList()
        return CopyFormat.parsePasskeys(String(AutofillKey.open(copy.readText())))
    }

    /**
     * Keeps in the clear only the picks [index] may name: all of them while it names accounts; while
     * it holds logins alone, a login's, not a code's, whose ids [copy] holds; none otherwise.
     */
    private fun keepNamedPicks(vault: String, copy: String, index: String) {
        val plain = file(vault, PLAIN_PICKS)
        when {
            CopyFormat.namesAccounts(index) -> Unit
            // An index for passkeys alone: the vault no longer names services, so its picks stay sealed
            !CopyFormat.holdsLogins(index) || !plain.exists() -> plain.delete()
            else -> try {
                val codes = CopyFormat.parseCopy(copy).map { it.id }.toSet()
                val kept = CopyFormat.parsePlainPicks(vault, plain.readText()).filter { it.account !in codes }
                if (kept.isEmpty()) plain.delete() else writeAtomically(plain, CopyFormat.plainPicks(kept))
            } catch (_: Exception) {
                plain.delete()
            }
        }
    }

    /**
     * Remembers [pick], sealed, and in the clear too while its vault names it in suggestions: a
     * code's while the vault names services, a [login]'s while its passwords are on.
     */
    fun remember(pick: Pick, login: Boolean = false) {
        dir.mkdirs()
        file(pick.vault, PICKS).appendText(AutofillKey.seal(pick.toJson().toByteArray()) + "\n")
        val index = file(pick.vault, INDEX).takeIf { it.exists() }?.readText() ?: return
        if (!CopyFormat.namesAccounts(index) && !(login && CopyFormat.holdsLogins(index))) return
        val plain = file(pick.vault, PLAIN_PICKS)
        val known = try {
            if (plain.exists()) CopyFormat.parsePlainPicks(pick.vault, plain.readText()) else emptyList()
        } catch (_: Exception) {
            emptyList()
        }
        writeAtomically(plain, CopyFormat.plainPicks(known.filter { it.target != pick.target || it.account != pick.account } + pick))
    }

    private fun writeAtomically(target: File, text: String) {
        val temp = File(target.parentFile, "${target.name}.tmp")
        temp.writeText(text)
        if (!temp.renameTo(target)) {
            temp.delete()
            throw java.io.IOException("Couldn't write ${target.name}")
        }
    }

    companion object {
        private const val COPY = ".copy"
        private const val INDEX = ".index.json"
        private const val PICKS = ".picks"
        private const val PLAIN_PICKS = ".picks.json"
        private const val NO_CODES = ".nocodes"
        private const val TAKES = ".takes.json"
        private val validVault = Regex("^[A-Za-z0-9_-]{1,64}$")
    }
}
