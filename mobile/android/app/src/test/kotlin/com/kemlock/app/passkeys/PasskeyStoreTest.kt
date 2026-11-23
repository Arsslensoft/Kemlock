package com.kemlock.app.passkeys

import com.kemlock.app.autofill.KeyInvalidatedException
import com.kemlock.app.autofill.fixture
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class PasskeyStoreTest {
    private val root: File = Files.createTempDirectory("passkeys").toFile()
    private val inbox = JSONObject(fixture("passkeys/passkeys.json").readText()).getJSONObject("inbox")
    private val inboxKey = inbox.getJSONObject("key")
    private val point = B64.decode(inboxKey.getString("point"))
    private val record = InboxRecord.parse(inbox.getJSONObject("record").toString())

    /** Stands in for the autofill key: reversible, and broken on demand as new biometrics break it. */
    private class FakeSealer : PasskeyStore.Sealer {
        var invalidated = false
        var failing = false

        override fun seal(plain: ByteArray): String {
            if (failing) throw IllegalStateException("No key")
            return "sealed:" + B64.encode(plain)
        }

        override fun open(envelope: String): ByteArray {
            if (invalidated) throw KeyInvalidatedException()
            return B64.decode(envelope.removePrefix("sealed:"))
        }
    }

    private val sealer = FakeSealer()
    private val store = PasskeyStore(root, sealer)

    @After
    fun cleanUp() {
        root.deleteRecursively()
    }

    /** Opens an inbox file as the app does, with the inbox key's private half. */
    private fun openInbox(file: String): String {
        val o = JSONObject(file)
        val epk = B64.decode(o.getString("epk"))
        val shared = P256.sharedSecret(P256.privateKey(B64.decode(inboxKey.getString("privateKey"))), epk)
        return Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, SecretKeySpec(Inbox.fileKey(shared, epk, point), "AES"), GCMParameterSpec(128, B64.decode(o.getString("nonce"))))
            String(doFinal(B64.decode(o.getString("ct"))))
        }
    }

    @Test
    fun keepsAVaultsInboxKeyWhilePasskeysAreOn() {
        assertNull(store.inboxKey("main"))
        assertEquals(emptyList<String>(), store.vaults())
        store.setInboxKey("main", point)
        store.setInboxKey("ab12cd", point)
        assertArrayEquals(point, store.inboxKey("main"))
        assertEquals(listOf("ab12cd", "main"), store.vaults())
        try {
            store.setInboxKey("main", point.copyOf(64))
            throw AssertionError("A short point was kept")
        } catch (_: IllegalArgumentException) {
            // refused
        }
    }

    @Test
    fun savesTheInboxFileAndTheProvidersOwnRecord() {
        store.setInboxKey("main", point)
        val name = store.save("main", record)
        assertEquals("AAECAwQFBgcICQoLDA0ODw.json", name)

        // The inbox file the app opens with the vault's inbox key
        val files = store.readInbox("main")
        assertEquals(listOf(name), files.map { it.first })
        assertEquals(record.toJson(), openInbox(files.single().second))

        // The record the provider signs in with before the app has run, and what it offers before biometrics
        val offered = store.created().single()
        assertEquals("main", offered.vault)
        assertEquals("webauthn.io", offered.rpId)
        assertEquals("fixture@example.org", offered.userName)
        assertNull(offered.privateKey)
        val opened = store.openCreated("main").single()
        assertEquals(record.privateKey, opened.privateKey)
        assertEquals(record.userHandle, opened.userHandle)
        assertTrue(File(root, "autofill/created/main/$name").readText().contains("\"sealed\":\"sealed:"))
    }

    @Test
    fun savesNothingWhilePasskeysAreOff() {
        try {
            store.save("main", record)
            throw AssertionError("Saved without an inbox key")
        } catch (_: IllegalStateException) {
            // refused
        }
        assertEquals(emptyList<Pair<String, String>>(), store.readInbox("main"))
    }

    @Test
    fun keepsTheInboxFileWhenTheHardwareKeyFails() {
        store.setInboxKey("main", point)
        sealer.failing = true
        store.save("main", record)
        assertEquals(1, store.readInbox("main").size)
        assertEquals(emptyList<Any>(), store.created())
    }

    @Test
    fun saysWhenBiometricsChanged() {
        store.setInboxKey("main", point)
        store.save("main", record)
        sealer.invalidated = true
        try {
            store.openCreated("main")
            throw AssertionError("Opened with an invalidated key")
        } catch (_: KeyInvalidatedException) {
            // the screen says to open Kemlock once
        }
    }

    @Test
    fun clearsWhatTheAppTookIn() {
        store.setInboxKey("main", point)
        val name = store.save("main", record)
        store.clearInbox("main", listOf("../main.key", name, "unknown.json"))
        assertEquals(emptyList<Pair<String, String>>(), store.readInbox("main"))
        assertEquals(emptyList<Any>(), store.created())
        assertArrayEquals(point, store.inboxKey("main"))
    }

    @Test
    fun turningPasskeysOffForgetsTheKeyAndRecordsButKeepsTheInbox() {
        store.setInboxKey("main", point)
        store.save("main", record)
        store.setInboxKey("main", null)
        assertNull(store.inboxKey("main"))
        assertEquals(emptyList<Any>(), store.created())
        assertEquals(1, store.readInbox("main").size)
    }

    // openspec: add-passwords, task 5.4
    @Test
    fun passkeysTurnedOffWhileSavingLoginsKeepTheKeyAndForgetTheRecords() {
        store.setInboxKey("main", point)
        store.save("main", record)
        store.forgetCreated("main")
        assertEquals(B64.encode(point), B64.encode(store.inboxKey("main")!!))
        assertEquals(emptyList<Any>(), store.created())
        assertEquals(1, store.readInbox("main").size)
    }

    @Test
    fun removesAVaultsFilesAndEveryones() {
        store.setInboxKey("main", point)
        store.setInboxKey("ab12cd", point)
        store.save("main", record)
        store.save("ab12cd", record)
        store.removeVault("main")
        assertNull(store.inboxKey("main"))
        assertEquals(emptyList<Pair<String, String>>(), store.readInbox("main"))
        assertEquals(listOf("ab12cd"), store.created().map { it.vault })
        store.removeAll()
        assertEquals(emptyList<String>(), store.vaults())
        assertEquals(emptyList<Any>(), store.created())
        assertEquals(emptyList<Pair<String, String>>(), store.readInbox("ab12cd"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun refusesAPathForAVault() {
        store.readInbox("../autofill")
    }
}
