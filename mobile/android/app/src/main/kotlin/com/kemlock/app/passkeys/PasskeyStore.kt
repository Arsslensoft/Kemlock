package com.kemlock.app.passkeys

import android.content.Context
import android.os.Build
import androidx.annotation.RequiresApi
import com.kemlock.app.autofill.AutofillKey
import com.kemlock.app.autofill.KeyInvalidatedException
import com.kemlock.app.autofill.PasskeyEntry
import com.kemlock.app.passwords.LoginInbox
import com.kemlock.app.passwords.LoginRecord
import org.json.JSONObject
import java.io.File
import java.io.IOException

/**
 * What the passkey provider keeps outside the vault (design decision 6), in `noBackupFilesDir`
 * beside autofill's files:
 *
 * - `inbox/<vault>.key`: the public point of the vault's inbox key, base64, while passkeys or
 *   saving logins are on.
 * - `inbox/<vault>/<name>`: a passkey made while the vault was locked, sealed to that key
 *   ([Inbox]), until the app has taken it in and clears it; or, named `login-<uuid>.json`, a login
 *   saved or a password generated ([LoginInbox]).
 * - `autofill/created/<vault>/<name>`: the same passkey sealed to [AutofillKey], with its site and
 *   account in the clear, so the provider signs in with it before the app has run. It goes with
 *   its inbox file, and with everything else sealed to that key when biometrics change; the inbox
 *   file stays, since its key is in the vault.
 *
 * A file's name is the passkey's credential id, base64url, with `.json`.
 */
@RequiresApi(Build.VERSION_CODES.O)
class PasskeyStore(root: File, private val sealer: Sealer = HardwareSealer) {
    constructor(context: Context) : this(context.noBackupFilesDir)

    /** Seals the provider's own records; [AutofillKey] on the phone. */
    interface Sealer {
        fun seal(plain: ByteArray): String

        /** Throws [KeyInvalidatedException] once the key can't open anything any more. */
        fun open(envelope: String): ByteArray
    }

    object HardwareSealer : Sealer {
        override fun seal(plain: ByteArray): String = AutofillKey.seal(plain)

        override fun open(envelope: String): ByteArray = AutofillKey.open(envelope)
    }

    private val inbox = File(root, "inbox")
    private val created = File(root, "autofill/created")

    private fun keyFile(vault: String) = File(inbox, "${checked(vault)}.key")

    private fun inboxDir(vault: String) = File(inbox, checked(vault))

    private fun createdDir(vault: String) = File(created, checked(vault))

    /**
     * The vaults with an inbox key, by id: those the phone may save to, passkeys while
     * [com.kemlock.app.autofill.AutofillStore.takesPasskeys] says so, logins while
     * [com.kemlock.app.autofill.AutofillStore.takesLogins] does.
     */
    fun vaults(): List<String> = inbox.listFiles()?.filter { it.isFile && it.name.endsWith(KEY) }
        ?.map { it.name.removeSuffix(KEY) }?.filter { validVault.matches(it) }?.sorted().orEmpty()

    /** The public point of [vault]'s inbox key, or null while its passkeys are off. */
    fun inboxKey(vault: String): ByteArray? {
        val file = keyFile(vault)
        if (!file.exists()) return null
        return try {
            B64.decode(file.readText().trim()).takeIf { it.size == 65 }
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    /**
     * Keeps [point] as [vault]'s inbox key; null forgets it, with the provider's own records of
     * the vault's passkeys, as passkeys turned off. Its inbox files stay for the app to take in.
     */
    fun setInboxKey(vault: String, point: ByteArray?) {
        if (point == null) {
            keyFile(vault).delete()
            createdDir(vault).deleteRecursively()
            return
        }
        P256.publicKey(point) // throws for anything but a P-256 point
        inbox.mkdirs()
        writeAtomically(keyFile(vault), B64.encode(point))
    }

    /** The inbox files waiting for [vault], oldest first: each one's name and content. */
    fun readInbox(vault: String): List<Pair<String, String>> = inboxDir(vault).listFiles()
        ?.filter { it.isFile && validName.matches(it.name) }
        ?.sortedWith(compareBy({ it.lastModified() }, { it.name }))
        ?.map { it.name to it.readText() }.orEmpty()

    /** Deletes the inbox files [names] of [vault], which the app has taken in, and the provider's records of them. */
    fun clearInbox(vault: String, names: List<String>) {
        for (name in names.filter { validName.matches(it) }) {
            File(inboxDir(vault), name).delete()
            File(createdDir(vault), name).delete()
        }
    }

    /**
     * Saves [record], made for [vault]: its inbox file first, from which the vault takes it in,
     * then the provider's own record, which can fail without losing the passkey. Returns the
     * file's name. Throws when passkeys are off for the vault or the inbox file can't be written.
     */
    fun save(vault: String, record: InboxRecord): String {
        val recipient = inboxKey(vault) ?: throw IllegalStateException("Passkeys are off for $vault")
        val name = "${record.credentialId}$JSON"
        require(validName.matches(name)) { "Not a credential id: ${record.credentialId}" }
        inboxDir(vault).mkdirs()
        writeAtomically(File(inboxDir(vault), name), Inbox.seal(record, recipient))
        try {
            val sealed = sealer.seal(record.toJson().toByteArray(Charsets.UTF_8))
            createdDir(vault).mkdirs()
            writeAtomically(
                File(createdDir(vault), name),
                Json.write(linkedMapOf("v" to VERSION, "passkey" to plain(record), "sealed" to sealed)),
            )
        } catch (_: Exception) {
            // The inbox file brings it into the vault; until then it can't sign in
        }
        return name
    }

    /**
     * Saves [record] for [vault] as a login file of its inbox (`login-<uuid>.json`, see
     * [LoginInbox]), which the vault takes in when it is next opened. Returns the file's name.
     * Throws when the vault has no inbox key or the file can't be written.
     */
    fun saveLogin(vault: String, record: LoginRecord): String {
        val recipient = inboxKey(vault) ?: throw IllegalStateException("Saving is off for $vault")
        val name = LoginInbox.fileName()
        inboxDir(vault).mkdirs()
        writeAtomically(File(inboxDir(vault), name), LoginInbox.seal(record, recipient))
        return name
    }

    /** Forgets the passkeys the provider made for [vault], whose passkeys were turned off; its inbox files stay for the app. */
    fun forgetCreated(vault: String) {
        createdDir(vault).deleteRecursively()
    }

    /** The provider's own records of every vault, without keys, for what the phone offers before biometrics. */
    fun created(): List<PasskeyEntry> = created.listFiles()?.filter { it.isDirectory && validVault.matches(it.name) }
        ?.sortedBy { it.name }?.flatMap { dir -> records(dir).mapNotNull { (_, o) -> entry(dir.name, o.optJSONObject("passkey")) } }.orEmpty()

    /**
     * [vault]'s own records, with their keys. Needs biometrics just before; throws
     * [KeyInvalidatedException] once biometrics changed since they were sealed.
     */
    fun openCreated(vault: String): List<PasskeyEntry> = records(createdDir(vault)).mapNotNull { (_, o) ->
        try {
            val r = InboxRecord.parse(String(sealer.open(o.getString("sealed")), Charsets.UTF_8))
            PasskeyEntry(vault, r.credentialId, r.rpId, r.rpName, r.userHandle, r.userName, r.userDisplayName, r.privateKey)
        } catch (e: KeyInvalidatedException) {
            throw e
        } catch (_: Exception) {
            null
        }
    }

    /** Everything of [vault]: its inbox key, its inbox files and the provider's records. */
    fun removeVault(vault: String) {
        keyFile(vault).delete()
        inboxDir(vault).deleteRecursively()
        createdDir(vault).deleteRecursively()
    }

    /** Every vault's inbox keys, inbox files and records. */
    fun removeAll() {
        inbox.deleteRecursively()
        created.deleteRecursively()
    }

    private fun records(dir: File): List<Pair<String, JSONObject>> = dir.listFiles()
        ?.filter { it.isFile && validName.matches(it.name) }?.sortedBy { it.name }
        ?.mapNotNull { file ->
            try {
                val o = JSONObject(file.readText())
                if (o.optInt("v") == VERSION) file.name to o else null
            } catch (_: Exception) {
                null
            }
        }.orEmpty()

    private fun plain(record: InboxRecord): Map<String, Any?> = linkedMapOf(
        "credentialId" to record.credentialId,
        "rpId" to record.rpId,
        "rpName" to record.rpName,
        "userHandle" to record.userHandle,
        "userName" to record.userName,
        "userDisplayName" to record.userDisplayName,
    )

    private fun entry(vault: String, o: JSONObject?): PasskeyEntry? {
        if (o == null) return null
        fun optional(name: String): String? = (o.opt(name) as? String)?.ifEmpty { null }
        return PasskeyEntry(
            vault = vault,
            credentialId = optional("credentialId") ?: return null,
            rpId = optional("rpId") ?: return null,
            rpName = optional("rpName"),
            userHandle = optional("userHandle") ?: return null,
            userName = optional("userName").orEmpty(),
            userDisplayName = optional("userDisplayName"),
        )
    }

    private fun checked(vault: String): String {
        require(validVault.matches(vault)) { "Not a vault id: $vault" }
        return vault
    }

    private fun writeAtomically(target: File, text: String) {
        val temp = File(target.parentFile, "${target.name}.tmp")
        temp.writeText(text)
        if (!temp.renameTo(target)) {
            temp.delete()
            throw IOException("Couldn't write ${target.name}")
        }
    }

    companion object {
        private const val VERSION = 1
        private const val KEY = ".key"
        private const val JSON = ".json"
        private val validVault = Regex("^[A-Za-z0-9_-]{1,64}$")
        private val validName = Regex("^[A-Za-z0-9_-]{1,200}\\.json$")
    }
}
