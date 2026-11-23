package com.kemlock.app.passwords

import com.kemlock.app.autofill.fixture
import com.kemlock.app.passkeys.B64
import com.kemlock.app.passkeys.Inbox
import com.kemlock.app.passkeys.P256
import com.kemlock.app.passkeys.PasskeyStore
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

private fun hex(text: String) = ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

/** A record of test/fixtures/passkeys/logins.json, as Kotlin builds it. */
private fun recordOf(o: JSONObject): LoginRecord {
    fun optional(key: String): String? = (o.opt(key) as? String)?.ifEmpty { null }
    return when (o.getString("kind")) {
        "login" -> LoginRecord.Saved(
            id = o.getString("id"),
            name = o.getString("name"),
            username = optional("username"),
            password = o.getString("password"),
            site = optional("site"),
            app = o.optJSONObject("app")?.let { InboxApp(it.getString("package"), it.getString("cert")) },
            generated = o.getBoolean("generated"),
            at = o.getLong("at"),
        )
        else -> LoginRecord.Generated(o.getString("password"), optional("site"), o.getLong("at"))
    }
}

// openspec: add-passwords, task 5.5
class LoginInboxTest {
    private val passkeys = JSONObject(fixture("passkeys/passkeys.json").readText()).getJSONObject("inbox")
    private val inboxKey = passkeys.getJSONObject("key")
    private val ephemeral = passkeys.getJSONObject("ephemeral")
    private val recipient = B64.decode(inboxKey.getString("point"))
    private val root: File = Files.createTempDirectory("logins").toFile()

    @After
    fun cleanUp() {
        root.deleteRecursively()
    }

    /** Opens a login file with the fixture's inbox key, as the app does. */
    private fun open(file: String): String {
        val o = JSONObject(file)
        val epk = B64.decode(o.getString("epk"))
        val shared = P256.sharedSecret(P256.privateKey(B64.decode(inboxKey.getString("privateKey"))), epk)
        val key = Inbox.hkdf(shared, salt = epk + recipient, info = LoginInbox.INFO.toByteArray())
        return Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, B64.decode(o.getString("nonce"))))
            String(doFinal(B64.decode(o.getString("ct"))))
        }
    }

    @Test
    fun sealsEveryRecordToTheFileDartWrote() {
        val cases = JSONObject(fixture("passkeys/logins.json").readText()).getJSONArray("cases")
        val key = P256.privateKey(B64.decode(ephemeral.getString("privateKey"))) to B64.decode(ephemeral.getString("point"))
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val sealed = LoginInbox.seal(recordOf(case.getJSONObject("record")), recipient, key, hex(case.getString("nonce")))
            assertEquals(case.getString("name"), case.getString("file"), sealed)
        }
        assertEquals(3, cases.length())
    }

    @Test
    fun savesALoginFileToTheVaultsInboxBesideItsPasskeys() {
        val store = PasskeyStore(root)
        store.setInboxKey("main", recipient)
        val record = LoginRecord.Saved("5f0c9a8e", "larkspur.example", "ada@example.org", "hunter2", "larkspur.example", null, false, 1795300000000)

        val name = store.saveLogin("main", record)

        assertTrue(name, Regex("^login-[0-9a-f-]{36}\\.json$").matches(name))
        val (listed, content) = store.readInbox("main").single()
        assertEquals(name, listed)
        assertEquals(record.toJson(), open(content))
        // Sealed afresh each time: no two files share an ephemeral key
        assertFalse(content == LoginInbox.seal(record, recipient))
        assertFalse(record.toString().contains("hunter2"))
    }

    @Test(expected = IllegalStateException::class)
    fun savesNothingForAVaultWithoutAnInboxKey() {
        PasskeyStore(root).saveLogin("main", LoginRecord.Generated("x", null, 1))
    }
}
