package com.kemlock.app.passkeys

import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.Signature
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.KeyAgreement

/**
 * The P-256 keys of passkeys and the passkey inbox, on the platform's own EC (as
 * lib/features/passkeys/p256.dart does in Dart): making a pair, PKCS#8 as `openssl pkey` writes
 * it, points as X9.63 uncompressed (0x04, x, y), key agreement, and ES256 signatures in DER.
 * Keys go through PKCS#8 and SPKI rather than curve parameters, which every provider reads.
 */
object P256 {
    private val p = BigInteger("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff", 16)
    private val b = BigInteger("5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b", 16)
    private val n = BigInteger("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", 16)

    // SubjectPublicKeyInfo of a P-256 key, up to the point.
    private val spkiPrefix = hex("3059301306072a8648ce3d020106082a8648ce3d030107034200")

    // PKCS#8 of a P-256 key with its public point, around the scalar and the point.
    private val pkcs8Prefix = hex("308187020100301306072a8648ce3d020106082a8648ce3d030107046d306b0201010420")
    private val pkcs8Middle = hex("a144034200")

    private val random = SecureRandom()

    /** A new key pair, from the platform's secure random source. */
    fun newKeyPair(): KeyPair = KeyPairGenerator.getInstance("EC").run {
        initialize(ECGenParameterSpec("secp256r1"), random)
        generateKeyPair()
    }

    /** The public point of [key], 65 bytes. */
    fun point(key: PublicKey): ByteArray {
        val w = (key as ECPublicKey).w
        return byteArrayOf(4) + unsigned(w.affineX) + unsigned(w.affineY)
    }

    /** The private scalar of [key], 32 bytes. */
    fun scalar(key: PrivateKey): ByteArray = unsigned((key as ECPrivateKey).s)

    /** The key pair with scalar [d] and public [point] as PKCS#8 DER, as `openssl pkey` and Dart write it. */
    fun pkcs8(d: ByteArray, point: ByteArray): ByteArray {
        require(d.size == 32) { "A P-256 scalar is 32 bytes" }
        checkPoint(point)
        return pkcs8Prefix + d + pkcs8Middle + point
    }

    /** [pair] as PKCS#8 DER, with its public point. */
    fun pkcs8(pair: KeyPair): ByteArray = pkcs8(scalar(pair.private), point(pair.public))

    /** The private key of a PKCS#8 file. Throws for anything but a P-256 key. */
    fun privateKey(pkcs8: ByteArray): PrivateKey {
        val key = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(pkcs8)) as? ECPrivateKey
            ?: throw IllegalArgumentException("Not an EC key")
        require(key.params.order == n) { "Not a P-256 key" }
        return key
    }

    /** The public key at [point], once it is checked to be on the curve. */
    fun publicKey(point: ByteArray): PublicKey {
        checkPoint(point)
        return KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(spkiPrefix + point))
    }

    /** [point]'s public key as SubjectPublicKeyInfo DER, as WebAuthn's `publicKey` field holds it. */
    fun spki(point: ByteArray): ByteArray {
        checkPoint(point)
        return spkiPrefix + point
    }

    /** The ECDH shared secret of [key] and the key at [peer]: the x coordinate, 32 bytes. */
    fun sharedSecret(key: PrivateKey, peer: ByteArray): ByteArray = KeyAgreement.getInstance("ECDH").run {
        init(key)
        doPhase(publicKey(peer), true)
        generateSecret()
    }

    /** An ES256 signature of [message] by [key]: ECDSA over SHA-256, DER, as WebAuthn wants it. */
    fun sign(key: PrivateKey, message: ByteArray): ByteArray = Signature.getInstance("SHA256withECDSA").run {
        initSign(key, random)
        update(message)
        sign()
    }

    /** Whether [signature], DER, is an ES256 signature of [message] by the key at [point]. */
    fun verify(point: ByteArray, message: ByteArray, signature: ByteArray): Boolean = try {
        Signature.getInstance("SHA256withECDSA").run {
            initVerify(publicKey(point))
            update(message)
            verify(signature)
        }
    } catch (_: Exception) {
        false
    }

    /** Throws unless [point] is an uncompressed point on P-256: y² = x³ − 3x + b (mod p). */
    private fun checkPoint(point: ByteArray) {
        require(point.size == 65 && point[0] == 4.toByte()) { "Not an uncompressed P-256 point" }
        val x = BigInteger(1, point.copyOfRange(1, 33))
        val y = BigInteger(1, point.copyOfRange(33, 65))
        require(x < p && y < p) { "Not a P-256 point" }
        val right = x.pow(3).subtract(x.multiply(BigInteger.valueOf(3))).add(b).mod(p)
        require(y.multiply(y).mod(p) == right) { "Not on P-256" }
    }

    private fun unsigned(value: BigInteger): ByteArray {
        val bytes = value.toByteArray()
        return when {
            bytes.size == 32 -> bytes
            bytes.size > 32 -> bytes.copyOfRange(bytes.size - 32, bytes.size)
            else -> ByteArray(32 - bytes.size) + bytes
        }
    }

    private fun hex(text: String): ByteArray = text.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}
