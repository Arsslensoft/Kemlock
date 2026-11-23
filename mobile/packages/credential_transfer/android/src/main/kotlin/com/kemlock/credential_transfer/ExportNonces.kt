package com.kemlock.credential_transfer

import java.security.MessageDigest
import java.security.SecureRandom

/** Where [ExportNonces] keeps what it must remember between runs of the app: hash to vault id. */
interface NonceStore {
    fun read(): Map<String, String>

    fun write(entries: Map<String, String>)
}

/**
 * The secret ids of the export entries Kemlock has registered with the system (openspec: plan
 * add-credential-exchange, design decision 11). Android launches the exported activity with the
 * id of the entry the person picked, and the activity must know it before any Dart runs: the app
 * may not be running at all. So the ids are made here, given to the system, and kept only as
 * SHA-256 hashes next to the vault they stand for. What is on disk can say that an id is right and
 * can't give one, and Dart never sees them.
 */
class ExportNonces(private val store: NonceStore, private val random: SecureRandom = SecureRandom()) {
    /**
     * A new secret id for each of [vaultIds], by vault. They are not kept yet: [commit] keeps them
     * once the system has registered the entries, so that a failed registration leaves the old ids,
     * which the system still holds, valid.
     */
    fun issue(vaultIds: List<String>): Map<String, String> = vaultIds.associateWith { randomHex(random, ID_BYTES) }

    /** Keeps [issued] in place of every id kept before. */
    fun commit(issued: Map<String, String>) {
        store.write(issued.entries.associate { (vault, id) -> hash(id) to vault })
    }

    /** The vault the entry with [credId] stands for; null for an id that was never issued. */
    fun vaultOf(credId: String?): String? {
        if (credId.isNullOrEmpty()) return null
        return store.read()[hash(credId)]
    }

    /** Whether any id is kept, which is whether any export entry is registered with the system. */
    fun any(): Boolean = store.read().isNotEmpty()

    /** Forgets every id: nothing is answered until entries are registered again. */
    fun clear() = store.write(emptyMap())

    companion object {
        /** 256 bits. */
        const val ID_BYTES = 32

        fun hash(id: String): String = hex(MessageDigest.getInstance("SHA-256").digest(id.toByteArray(Charsets.UTF_8)))

        fun randomHex(random: SecureRandom, bytes: Int): String = hex(ByteArray(bytes).also { random.nextBytes(it) })

        private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }
    }
}
