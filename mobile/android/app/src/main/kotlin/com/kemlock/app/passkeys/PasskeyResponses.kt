package com.kemlock.app.passkeys

import android.os.Build
import androidx.annotation.RequiresApi
import com.kemlock.app.autofill.PasskeyEntry
import java.security.KeyPair
import java.security.SecureRandom

/**
 * What the provider answers, as androidx.credentials hands it on: WebAuthn's
 * `RegistrationResponseJSON` for a new passkey and `AuthenticationResponseJSON` for a sign-in,
 * binary fields in base64url. The client data names the [origin] the caller check gave: a
 * trusted browser's site, or an app's `android:apk-key-hash:`. A browser that hands over the hash
 * of its own client data is signed for that hash, and puts its client data in place of this one;
 * an app is always signed for the client data made here.
 */
@RequiresApi(Build.VERSION_CODES.O)
object PasskeyResponses {
    private val random = SecureRandom()

    /** How the origin of an Android app starts ([CallerCheck.appOrigin]); a website's never does. */
    private const val APP_ORIGIN = "android:apk-key-hash:"

    /** A new passkey: the record the vault takes in, and the response the site gets. */
    class Created(val record: InboxRecord, val json: String)

    /** 16 random bytes, which Bitwarden keeps as a GUID, so plain Vaultwarden storage round-trips. */
    fun newCredentialId(): ByteArray = ByteArray(16).also(random::nextBytes)

    fun clientDataJson(type: String, challenge: ByteArray, origin: String): String =
        Json.write(linkedMapOf("type" to type, "challenge" to B64.url(challenge), "origin" to origin, "crossOrigin" to false))

    /** A new ES256 passkey for [options] at [rpId], with attestation `none`. */
    fun create(
        options: CreationOptions,
        rpId: String,
        origin: String,
        createdAt: Long,
        keyPair: KeyPair = P256.newKeyPair(),
        credentialId: ByteArray = newCredentialId(),
    ): Created {
        require(options.acceptsEs256) { "The site doesn't take ES256" }
        val point = P256.point(keyPair.public)
        val authData = PasskeyBytes.registrationAuthData(rpId, credentialId, point)
        val id = B64.url(credentialId)
        val json = Json.write(
            linkedMapOf(
                "id" to id,
                "rawId" to id,
                "type" to "public-key",
                "authenticatorAttachment" to "platform",
                "response" to linkedMapOf(
                    "clientDataJSON" to B64.url(clientDataJson("webauthn.create", options.challenge, origin).toByteArray(Charsets.UTF_8)),
                    "attestationObject" to B64.url(PasskeyBytes.attestationObject(authData)),
                    "authenticatorData" to B64.url(authData),
                    "transports" to listOf("internal"),
                    "publicKeyAlgorithm" to PasskeyBytes.ES256,
                    "publicKey" to B64.url(P256.spki(point)),
                ),
                "clientExtensionResults" to if (options.credProps) mapOf("credProps" to mapOf("rk" to true)) else emptyMap(),
            ),
        )
        val record = InboxRecord(
            credentialId = id,
            rpId = rpId,
            rpName = options.rpName,
            userHandle = B64.url(options.userHandle),
            userName = options.userName,
            userDisplayName = options.userDisplayName,
            privateKey = B64.encode(P256.pkcs8(keyPair)),
            createdAt = createdAt,
        )
        return Created(record, json)
    }

    /**
     * A sign-in with [passkey], which has its key, for [challenge] from [origin]: the authenticator
     * data, signed with the client data's hash, or with [clientDataHash] when the browser gave one.
     * An app's hash is never signed: any app can put one in its request, and a signature over it
     * would vouch for client data Kemlock never saw, with whatever origin the app wrote there.
     */
    fun assertion(passkey: PasskeyEntry, challenge: ByteArray, origin: String, clientDataHash: ByteArray?): String {
        val key = P256.privateKey(B64.decode(passkey.privateKey ?: throw IllegalArgumentException("No key")))
        val authData = PasskeyBytes.assertionAuthData(passkey.rpId)
        val clientData = clientDataJson("webauthn.get", challenge, origin).toByteArray(Charsets.UTF_8)
        val browsersHash = clientDataHash?.takeIf { !origin.startsWith(APP_ORIGIN) }
        val signature = P256.sign(key, PasskeyBytes.signedBytes(authData, browsersHash ?: PasskeyBytes.sha256(clientData)))
        val id = B64.url(B64.fromUrl(passkey.credentialId))
        return Json.write(
            linkedMapOf(
                "id" to id,
                "rawId" to id,
                "type" to "public-key",
                "authenticatorAttachment" to "platform",
                "response" to linkedMapOf(
                    "clientDataJSON" to B64.url(clientData),
                    "authenticatorData" to B64.url(authData),
                    "signature" to B64.url(signature),
                    "userHandle" to B64.url(B64.fromUrl(passkey.userHandle)),
                ),
                "clientExtensionResults" to emptyMap<String, Any>(),
            ),
        )
    }
}
