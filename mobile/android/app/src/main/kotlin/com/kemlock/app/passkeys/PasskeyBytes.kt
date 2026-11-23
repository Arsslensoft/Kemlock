package com.kemlock.app.passkeys

import java.io.ByteArrayOutputStream
import java.security.MessageDigest

/**
 * The bytes a passkey provider hands a site (WebAuthn Level 3, CTAP 2.1), built as
 * lib/features/passkeys/passkey_bytes.dart builds them and pinned by test/fixtures/passkeys:
 *
 * - registration: authenticator data with the flags user present, user verified, backup
 *   eligible, backup state and attested credential data (0x5D), a signature counter of 0,
 *   Kemlock's AAGUID, the credential id and the ES256 public key as a COSE key; and the
 *   attestation object `{"fmt": "none", "attStmt": {}, "authData": …}` in canonical CBOR;
 * - assertion: authenticator data with user present, user verified, backup eligible and
 *   backup state (0x1D) and a counter of 0, and the bytes signed: that authenticator data
 *   followed by the client data's SHA-256.
 */
object PasskeyBytes {
    /** Kemlock's AAGUID, which says which provider made a passkey. */
    const val AAGUID = "f85899be-d2db-4b3b-9b10-9b48e146dc1c"

    /** COSE's number for ES256, ECDSA over P-256 with SHA-256: the only algorithm Kemlock makes. */
    const val ES256 = -7

    /** UP, UV, BE, BS, AT. */
    const val REGISTRATION_FLAGS = 0x01 or 0x04 or 0x08 or 0x10 or 0x40

    /** UP, UV, BE, BS. */
    const val ASSERTION_FLAGS = 0x01 or 0x04 or 0x08 or 0x10

    /** [AAGUID] as its 16 bytes. */
    val aaguid: ByteArray get() = AAGUID.replace("-", "").chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

    /** SHA-256 of the relying party's id, as authenticator data begins. */
    fun rpIdHash(rpId: String): ByteArray = sha256(rpId.toByteArray(Charsets.UTF_8))

    /** The ES256 public key at [point] (X9.63, 65 bytes) as a COSE key: `{1: 2, 3: -7, -1: 1, -2: x, -3: y}`. */
    fun coseKey(point: ByteArray): ByteArray {
        require(point.size == 65 && point[0] == 4.toByte()) { "Not an uncompressed P-256 point" }
        return Cbor.map(
            listOf(
                Cbor.integer(1) to Cbor.integer(2),
                Cbor.integer(3) to Cbor.integer(ES256.toLong()),
                Cbor.integer(-1) to Cbor.integer(1),
                Cbor.integer(-2) to Cbor.bytes(point.copyOfRange(1, 33)),
                Cbor.integer(-3) to Cbor.bytes(point.copyOfRange(33, 65)),
            ),
        )
    }

    /** A registration's authenticator data for a new passkey. */
    fun registrationAuthData(rpId: String, credentialId: ByteArray, point: ByteArray): ByteArray {
        require(credentialId.size in 1..1023) { "Credential ids are 1 to 1023 bytes" }
        return ByteArrayOutputStream().apply {
            write(rpIdHash(rpId))
            write(REGISTRATION_FLAGS)
            write(ByteArray(4))
            write(aaguid)
            write(credentialId.size shr 8)
            write(credentialId.size and 0xff)
            write(credentialId)
            write(coseKey(point))
        }.toByteArray()
    }

    /** The attestation object of a registration, attestation `none`. */
    fun attestationObject(authData: ByteArray): ByteArray = Cbor.map(
        listOf(
            Cbor.text("fmt") to Cbor.text("none"),
            Cbor.text("attStmt") to Cbor.map(emptyList()),
            Cbor.text("authData") to Cbor.bytes(authData),
        ),
    )

    /** An assertion's authenticator data. */
    fun assertionAuthData(rpId: String): ByteArray = rpIdHash(rpId) + byteArrayOf(ASSERTION_FLAGS.toByte(), 0, 0, 0, 0)

    /** What an assertion signs: its authenticator data, then the client data's hash. */
    fun signedBytes(authData: ByteArray, clientDataHash: ByteArray): ByteArray = authData + clientDataHash
}

/**
 * The little CBOR passkeys need: integers, byte and text strings, and maps, each in its shortest
 * form. A map's entries are written in the order given, which callers keep canonical.
 */
object Cbor {
    private fun head(major: Int, value: Long): ByteArray {
        val m = major shl 5
        return when {
            value < 24 -> byteArrayOf((m or value.toInt()).toByte())
            value < 0x100 -> byteArrayOf((m or 24).toByte(), value.toByte())
            value < 0x10000 -> byteArrayOf((m or 25).toByte(), (value shr 8).toByte(), value.toByte())
            else -> byteArrayOf((m or 26).toByte(), (value shr 24).toByte(), (value shr 16).toByte(), (value shr 8).toByte(), value.toByte())
        }
    }

    fun integer(value: Long): ByteArray = if (value >= 0) head(0, value) else head(1, -1 - value)

    fun integer(value: Int): ByteArray = integer(value.toLong())

    fun bytes(value: ByteArray): ByteArray = head(2, value.size.toLong()) + value

    fun text(value: String): ByteArray {
        val encoded = value.toByteArray(Charsets.UTF_8)
        return head(3, encoded.size.toLong()) + encoded
    }

    fun map(entries: List<Pair<ByteArray, ByteArray>>): ByteArray = ByteArrayOutputStream().apply {
        write(head(5, entries.size.toLong()))
        for ((key, value) in entries) {
            write(key)
            write(value)
        }
    }.toByteArray()
}
