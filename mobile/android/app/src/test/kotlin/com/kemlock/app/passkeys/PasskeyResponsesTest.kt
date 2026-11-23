package com.kemlock.app.passkeys

import com.kemlock.app.autofill.PasskeyEntry
import com.kemlock.app.autofill.fixture
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyPair

/** The JSON the provider answers with, held to test/fixtures/passkeys. */
class PasskeyResponsesTest {
    private val fixture = JSONObject(fixture("passkeys/passkeys.json").readText())
    private val credential = fixture.getJSONObject("credential")
    private val point = B64.decode(credential.getString("point"))
    private val pkcs8 = B64.decode(credential.getString("privateKey"))
    private val record = fixture.getJSONObject("inbox").getJSONObject("record")
    private val challenge = "a2VtbG9jay1maXh0dXJlLWNoYWxsZW5nZQ"

    private fun bytes(o: JSONObject, key: String) = B64.decode(o.getString(key))

    private fun creation(params: String = """[{"type":"public-key","alg":-7},{"type":"public-key","alg":-257}]""", extra: String = "") =
        CreationOptions.parse(
            """{"rp":{"id":"webauthn.io","name":"WebAuthn.io"},
                "user":{"id":"dXNlci1maXh0dXJlLTE","name":"fixture@example.org","displayName":"Fixture User"},
                "challenge":"$challenge","pubKeyCredParams":$params,"timeout":60000,
                "authenticatorSelection":{"residentKey":"required","userVerification":"required"},"attestation":"none"$extra}""",
        )

    private fun created(options: CreationOptions = creation(), origin: String = "https://webauthn.io") = PasskeyResponses.create(
        options,
        rpId = "webauthn.io",
        origin = origin,
        createdAt = record.getLong("createdAt"),
        keyPair = KeyPair(P256.publicKey(point), P256.privateKey(pkcs8)),
        credentialId = ByteArray(16) { it.toByte() },
    )

    @Test
    fun answersARegistrationWithTheFixturesBytes() {
        val response = JSONObject(created().json)
        val registration = fixture.getJSONObject("registration")
        assertEquals(credential.getString("credentialId"), response.getString("id"))
        assertEquals(credential.getString("credentialId"), response.getString("rawId"))
        assertEquals("public-key", response.getString("type"))
        assertEquals("platform", response.getString("authenticatorAttachment"))
        val r = response.getJSONObject("response")
        assertArrayEquals(bytes(registration, "authData"), B64.fromUrl(r.getString("authenticatorData")))
        assertArrayEquals(bytes(registration, "attestationObject"), B64.fromUrl(r.getString("attestationObject")))
        assertEquals(-7, r.getInt("publicKeyAlgorithm"))
        val spki = B64.fromUrl(r.getString("publicKey"))
        assertArrayEquals(point, P256.point(P256.publicKey(spki.copyOfRange(spki.size - 65, spki.size))))
        assertEquals("internal", r.getJSONArray("transports").getString(0))
        assertEquals(
            """{"type":"webauthn.create","challenge":"$challenge","origin":"https://webauthn.io","crossOrigin":false}""",
            String(B64.fromUrl(r.getString("clientDataJSON"))),
        )
        assertEquals(0, response.getJSONObject("clientExtensionResults").length())
    }

    @Test
    fun recordsTheNewPasskeyAsTheAppTakesItIn() {
        val made = created().record
        // The fixture's record, which the app's inbox file holds, byte for byte
        assertEquals(InboxRecord.parse(record.toString()).toJson(), made.toJson())
        assertArrayEquals(pkcs8, B64.decode(made.privateKey))
        val inbox = fixture.getJSONObject("inbox")
        val ephemeral = inbox.getJSONObject("ephemeral")
        val file = Inbox.seal(
            made,
            B64.decode(inbox.getJSONObject("key").getString("point")),
            ephemeral = P256.privateKey(bytes(ephemeral, "privateKey")) to bytes(ephemeral, "point"),
            nonce = bytes(inbox, "nonce"),
        )
        assertEquals(inbox.getString("file"), file)
    }

    @Test
    fun answersCredPropsWhenAsked() {
        val response = JSONObject(created(creation(extra = ""","extensions":{"credProps":true}""")).json)
        assertTrue(response.getJSONObject("clientExtensionResults").getJSONObject("credProps").getBoolean("rk"))
    }

    @Test
    fun namesAnAppsOriginInTheClientData() {
        val r = JSONObject(created(origin = "android:apk-key-hash:AAAA").json).getJSONObject("response")
        assertEquals("android:apk-key-hash:AAAA", JSONObject(String(B64.fromUrl(r.getString("clientDataJSON")))).getString("origin"))
    }

    @Test
    fun makesAFreshKeyAndIdEachTime() {
        val first = PasskeyResponses.create(creation(), "webauthn.io", "https://webauthn.io", 1)
        val second = PasskeyResponses.create(creation(), "webauthn.io", "https://webauthn.io", 1)
        assertEquals(16, B64.fromUrl(first.record.credentialId).size)
        assertFalse(first.record.credentialId == second.record.credentialId)
        assertFalse(first.record.privateKey == second.record.privateKey)
        assertEquals(138, B64.decode(first.record.privateKey).size)
    }

    private val passkey = PasskeyEntry(
        vault = "main",
        credentialId = credential.getString("credentialId"),
        rpId = "webauthn.io",
        rpName = "WebAuthn.io",
        userHandle = record.getString("userHandle"),
        userName = record.getString("userName"),
        userDisplayName = null,
        privateKey = credential.getString("privateKey"),
    )

    @Test
    fun answersASignInWithTheFixturesBytesAndASignatureThatVerifies() {
        val assertion = fixture.getJSONObject("assertion")
        val response = JSONObject(PasskeyResponses.assertion(passkey, B64.fromUrl(challenge), "https://webauthn.io", null))
        assertEquals(credential.getString("credentialId"), response.getString("id"))
        assertEquals("public-key", response.getString("type"))
        val r = response.getJSONObject("response")
        assertEquals(assertion.getString("clientDataJSON"), String(B64.fromUrl(r.getString("clientDataJSON"))))
        val authData = B64.fromUrl(r.getString("authenticatorData"))
        assertArrayEquals(bytes(assertion, "authData"), authData)
        assertEquals(record.getString("userHandle"), r.getString("userHandle"))
        // Signed over the fixture's bytes, as the fixture's own signature is
        val signed = bytes(assertion, "signedBytes")
        assertTrue(P256.verify(point, signed, B64.fromUrl(r.getString("signature"))))
        assertTrue(P256.verify(point, signed, bytes(assertion, "signature")))
    }

    @Test
    fun signsTheHashABrowserGives() {
        val hash = ByteArray(32) { 9 }
        val r = JSONObject(PasskeyResponses.assertion(passkey, B64.fromUrl(challenge), "https://webauthn.io", hash)).getJSONObject("response")
        val signature = B64.fromUrl(r.getString("signature"))
        assertTrue(P256.verify(point, PasskeyBytes.assertionAuthData("webauthn.io") + hash, signature))
        assertFalse(P256.verify(point, bytes(fixture.getJSONObject("assertion"), "signedBytes"), signature))
    }

    @Test
    fun neverSignsTheHashAnAppGives() {
        // The hash of client data that says https://webauthn.io, from an app the site lists
        val hash = ByteArray(32) { 9 }
        val origin = "android:apk-key-hash:AAAA"
        val r = JSONObject(PasskeyResponses.assertion(passkey, B64.fromUrl(challenge), origin, hash)).getJSONObject("response")
        val signature = B64.fromUrl(r.getString("signature"))
        assertFalse(P256.verify(point, PasskeyBytes.assertionAuthData("webauthn.io") + hash, signature))
        // Signed for the client data it answers with, which names the app
        val clientData = B64.fromUrl(r.getString("clientDataJSON"))
        assertEquals(origin, JSONObject(String(clientData)).getString("origin"))
        assertTrue(P256.verify(point, PasskeyBytes.assertionAuthData("webauthn.io") + PasskeyBytes.sha256(clientData), signature))
    }

    @Test
    fun takesEs256OrWebAuthnsDefaults() {
        assertTrue(creation().acceptsEs256)
        assertTrue(creation("[]").acceptsEs256)
        assertTrue(creation("""[{"type":"public-key","alg":-8},{"type":"public-key","alg":-7}]""").acceptsEs256)
        assertFalse(creation("""[{"type":"public-key","alg":-257},{"type":"public-key","alg":-8}]""").acceptsEs256)
        assertFalse(creation("""[{"type":"other","alg":-7},{"type":"public-key","alg":-257}]""").acceptsEs256)
        assertThrows { creation("""[{"type":"other","alg":-7}]""") }
    }

    @Test
    fun readsTheCreationRequest() {
        val options = creation(extra = ""","excludeCredentials":[{"type":"public-key","id":"AAECAwQFBgcICQoLDA0ODw"},{"type":"public-key","id":"!!"}]""")
        assertEquals("webauthn.io", options.rpId)
        assertEquals("WebAuthn.io", options.rpName)
        assertEquals("fixture@example.org", options.userName)
        assertEquals("Fixture User", options.userDisplayName)
        assertArrayEquals("user-fixture-1".toByteArray(), options.userHandle)
        assertArrayEquals("kemlock-fixture-challenge".toByteArray(), options.challenge)
        assertEquals(1, options.excluded.size)
        assertArrayEquals(ByteArray(16) { it.toByte() }, options.excluded.single())
        assertFalse(options.credProps)
        // A browser may leave the relying party to the site's host
        assertNull(CreationOptions.parse("""{"rp":{"name":"x"},"user":{"id":"AQ","name":"a"},"challenge":"AQ"}""").rpId)
    }

    @Test
    fun refusesCreationRequestsItCantRead() {
        assertThrows { CreationOptions.parse("not json") }
        assertThrows { CreationOptions.parse("""{"user":{"id":"AQ","name":"a"},"challenge":"AQ"}""") }
        assertThrows { CreationOptions.parse("""{"rp":{"id":"a.io"},"user":{"name":"a"},"challenge":"AQ"}""") }
        assertThrows { CreationOptions.parse("""{"rp":{"id":"a.io"},"user":{"id":"AQ","name":"a"}}""") }
        assertThrows { CreationOptions.parse("""{"rp":{"id":"a.io"},"user":{"id":"AQ","name":"a"},"challenge":"!!"}""") }
        val long = B64.url(ByteArray(65))
        assertThrows { CreationOptions.parse("""{"rp":{"id":"a.io"},"user":{"id":"$long","name":"a"},"challenge":"AQ"}""") }
    }

    @Test
    fun readsTheSignInRequest() {
        val options = RequestOptions.parse(
            """{"challenge":"$challenge=","rpId":"WebAuthn.io","userVerification":"required",
                "allowCredentials":[{"type":"public-key","id":"AAECAwQFBgcICQoLDA0ODw","transports":["internal"]}]}""",
        )
        assertEquals("webauthn.io", options.rpId)
        assertArrayEquals("kemlock-fixture-challenge".toByteArray(), options.challenge)
        assertArrayEquals(ByteArray(16) { it.toByte() }, options.allowed.single())
        assertEquals(emptyList<ByteArray>(), RequestOptions.parse("""{"challenge":"AQ"}""").allowed)
        assertThrows { RequestOptions.parse("""{"rpId":"a.io"}""") }
    }

    private fun assertThrows(block: () -> Unit) {
        try {
            block()
        } catch (_: BadRequestException) {
            return
        }
        throw AssertionError("Expected BadRequestException")
    }
}
