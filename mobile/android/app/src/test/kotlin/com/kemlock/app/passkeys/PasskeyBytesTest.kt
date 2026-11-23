package com.kemlock.app.passkeys

import com.kemlock.app.autofill.fixture
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The passkey bytes and the inbox file of test/fixtures/passkeys, which the Dart and Swift tests
 * read too and which are never regenerated: the provider must build them byte for byte.
 */
class PasskeyBytesTest {
    private val fixture = JSONObject(fixture("passkeys/passkeys.json").readText())
    private val credential = fixture.getJSONObject("credential")
    private val point = bytes(credential, "point")
    private val rpId = credential.getString("rpId")

    private fun bytes(o: JSONObject, key: String) = B64.decode(o.getString(key))

    @Test
    fun theAaguidIsKemlocks() {
        assertEquals(fixture.getString("aaguid"), PasskeyBytes.AAGUID)
        assertEquals(16, PasskeyBytes.aaguid.size)
        assertEquals(0xf8.toByte(), PasskeyBytes.aaguid[0])
        assertEquals(0x1c.toByte(), PasskeyBytes.aaguid[15])
    }

    @Test
    fun writesAndReadsTheCredentialKeyAsPkcs8() {
        val pkcs8 = bytes(credential, "privateKey")
        assertArrayEquals(pkcs8, P256.pkcs8(bytes(credential, "d"), point))
        assertArrayEquals(bytes(credential, "d"), P256.scalar(P256.privateKey(pkcs8)))
        assertArrayEquals(point, P256.point(P256.publicKey(point)))
    }

    @Test
    fun buildsTheRegistrationBytes() {
        val registration = fixture.getJSONObject("registration")
        val credentialId = B64.fromUrl(credential.getString("credentialId"))
        assertArrayEquals(ByteArray(16) { it.toByte() }, credentialId)

        assertArrayEquals(bytes(registration, "coseKey"), PasskeyBytes.coseKey(point))
        val authData = PasskeyBytes.registrationAuthData(rpId, credentialId, point)
        assertArrayEquals(bytes(registration, "authData"), authData)
        assertArrayEquals(bytes(registration, "attestationObject"), PasskeyBytes.attestationObject(authData))
    }

    @Test
    fun buildsTheAssertionBytesAndItsSignaturesVerify() {
        val assertion = fixture.getJSONObject("assertion")
        val hash = PasskeyBytes.sha256(assertion.getString("clientDataJSON").toByteArray())
        assertArrayEquals(bytes(assertion, "clientDataHash"), hash)

        val authData = PasskeyBytes.assertionAuthData(rpId)
        assertArrayEquals(bytes(assertion, "authData"), authData)
        val signed = PasskeyBytes.signedBytes(authData, hash)
        assertArrayEquals(bytes(assertion, "signedBytes"), signed)

        // The fixture's deterministic signature, and one the platform makes now with fresh randomness
        assertTrue(P256.verify(point, signed, bytes(assertion, "signature")))
        val key = P256.privateKey(bytes(credential, "privateKey"))
        assertTrue(P256.verify(point, signed, P256.sign(key, signed)))
        assertFalse(P256.verify(point, signed + byteArrayOf(0), bytes(assertion, "signature")))
    }

    @Test
    fun sealsTheInboxRecordToTheSameFile() {
        val inbox = fixture.getJSONObject("inbox")
        val inboxKey = inbox.getJSONObject("key")
        val ephemeral = inbox.getJSONObject("ephemeral")
        val recipient = bytes(inboxKey, "point")
        val epk = bytes(ephemeral, "point")
        val ephemeralKey = P256.privateKey(bytes(ephemeral, "privateKey"))

        val shared = P256.sharedSecret(ephemeralKey, recipient)
        assertArrayEquals(bytes(inbox, "sharedSecret"), shared)
        assertArrayEquals(shared, P256.sharedSecret(P256.privateKey(bytes(inboxKey, "privateKey")), epk))
        assertArrayEquals(bytes(inbox, "fileKey"), Inbox.fileKey(shared, epk, recipient))

        val record = InboxRecord.parse(inbox.getJSONObject("record").toString())
        val file = Inbox.seal(record, recipient, ephemeral = ephemeralKey to epk, nonce = bytes(inbox, "nonce"))
        assertEquals(inbox.getString("file"), file)
    }

    @Test
    fun writesTheRecordAsDartDoes() {
        val inbox = fixture.getJSONObject("inbox")
        val sealed = JSONObject(inbox.getString("file"))
        val plain = open(bytes(inbox, "fileKey"), B64.decode(sealed.getString("nonce")), B64.decode(sealed.getString("ct")))
        // The record the app wrote is the record Kotlin writes, byte for byte
        assertEquals(String(plain), InboxRecord.parse(String(plain)).toJson())
        val record = InboxRecord.parse(String(plain))
        assertEquals("webauthn.io", record.rpId)
        assertEquals("Fixture User", record.userDisplayName)
        assertEquals(1763200000000L, record.createdAt)
    }

    @Test
    fun sealsAFreshFileTheInboxKeyOpens() {
        val inbox = fixture.getJSONObject("inbox")
        val inboxKey = inbox.getJSONObject("key")
        val recipient = bytes(inboxKey, "point")
        val record = InboxRecord("AQID", "example.com", null, "dQ", "alice", null, "AAAA", 5)

        val first = JSONObject(Inbox.seal(record, recipient))
        val second = JSONObject(Inbox.seal(record, recipient))
        assertEquals(1, first.getInt("v"))
        assertFalse(first.getString("epk") == second.getString("epk"))
        assertFalse(first.getString("nonce") == second.getString("nonce"))

        val epk = B64.decode(first.getString("epk"))
        val key = Inbox.fileKey(P256.sharedSecret(P256.privateKey(bytes(inboxKey, "privateKey")), epk), epk, recipient)
        val plain = String(open(key, B64.decode(first.getString("nonce")), B64.decode(first.getString("ct"))))
        assertEquals("""{"credentialId":"AQID","rpId":"example.com","userHandle":"dQ","userName":"alice","privateKey":"AAAA","createdAt":5}""", plain)
    }

    @Test(expected = AEADBadTagException::class)
    fun aChangedInboxFileDoesntOpen() {
        val inbox = fixture.getJSONObject("inbox")
        val sealed = JSONObject(inbox.getString("file"))
        val ct = B64.decode(sealed.getString("ct")).also { it[0] = (it[0].toInt() xor 1).toByte() }
        open(bytes(inbox, "fileKey"), B64.decode(sealed.getString("nonce")), ct)
    }

    @Test
    fun refusesPointsOffTheCurve() {
        val bad = point.copyOf().also { it[64] = (it[64].toInt() xor 1).toByte() }
        assertThrows { P256.publicKey(bad) }
        assertThrows { P256.publicKey(point.copyOf(33)) }
        assertThrows { PasskeyBytes.coseKey(point.copyOf(64)) }
    }

    @Test
    fun writesJsonAsDartsJsonEncode() {
        assertEquals(
            """{"a":"x/\"\\\n\t\u0001é😀","n":1763200000000,"b":true,"l":["\ud800",{}]}""",
            Json.write(linkedMapOf("a" to "x/\"\\\n\t\u0001é😀", "skipped" to null, "n" to 1763200000000L, "b" to true, "l" to listOf("\ud800", emptyMap<String, Any>()))),
        )
    }

    @Test
    fun encodesCborHeadsInTheirShortestForm() {
        assertArrayEquals(byteArrayOf(0x17), Cbor.integer(23))
        assertArrayEquals(byteArrayOf(0x18, 0x18), Cbor.integer(24))
        assertArrayEquals(byteArrayOf(0x19, 0x01, 0x00), Cbor.integer(256))
        assertArrayEquals(byteArrayOf(0x1a, 0x00, 0x01, 0x00, 0x00), Cbor.integer(65536))
        assertArrayEquals(byteArrayOf(0x26), Cbor.integer(-7))
        assertArrayEquals(byteArrayOf(0x38, 0x18), Cbor.integer(-25))
        assertArrayEquals(byteArrayOf(0x40), Cbor.bytes(ByteArray(0)))
        assertArrayEquals(byteArrayOf(0x63, 0x66, 0x6d, 0x74), Cbor.text("fmt"))
        assertArrayEquals(byteArrayOf(0xa0.toByte()), Cbor.map(emptyList()))
    }

    private fun open(key: ByteArray, nonce: ByteArray, ct: ByteArray): ByteArray = Cipher.getInstance("AES/GCM/NoPadding").run {
        init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        doFinal(ct)
    }

    private fun assertThrows(block: () -> Unit) {
        try {
            block()
        } catch (_: IllegalArgumentException) {
            return
        }
        throw AssertionError("Expected IllegalArgumentException")
    }
}
