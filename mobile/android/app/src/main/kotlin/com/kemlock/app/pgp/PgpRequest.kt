package com.kemlock.app.pgp

import android.content.Intent
import android.os.Bundle
import org.openintents.openpgp.OpenPgpDecryptionResult
import org.openintents.openpgp.OpenPgpError
import org.openintents.openpgp.OpenPgpMetadata
import org.openintents.openpgp.OpenPgpSignatureResult
import org.openintents.openpgp.util.OpenPgpApi
import java.security.SecureRandom
import java.util.Date

/**
 * A mail app's request as the channel `com.kemlock.app/mail` carries it, and Dart's answer back
 * as the API's result Intent (openspec: add-pgp-mail-provider, decision 9). The map side is free
 * of Android's types, for the JVM tests; [PgpIntents] is the Android side.
 */
object PgpRequest {
    /** What an extra of a request's Intent holds, as `OpenPgpApi` documents each. */
    enum class ExtraType { INT, BOOLEAN, LONG, TEXT, TEXTS, LONGS, BYTES }

    /**
     * The extras Kemlock reads (lib/platform/mail_requests.dart's `mailExtras`), each with the
     * type it is read as; never the passphrase. Nothing else of a request's Intent is read:
     * [PgpIntents.read] asks for these by name and type, and leaves whatever else an app put
     * there as it came.
     */
    val EXTRA_TYPES: Map<String, ExtraType> = mapOf(
        OpenPgpApi.EXTRA_API_VERSION to ExtraType.INT,
        OpenPgpApi.EXTRA_REQUEST_ASCII_ARMOR to ExtraType.BOOLEAN,
        OpenPgpApi.EXTRA_USER_IDS to ExtraType.TEXTS,
        OpenPgpApi.EXTRA_KEY_IDS to ExtraType.LONGS,
        OpenPgpApi.EXTRA_SIGN_KEY_ID to ExtraType.LONG,
        OpenPgpApi.EXTRA_USER_ID to ExtraType.TEXT,
        OpenPgpApi.EXTRA_KEY_ID to ExtraType.LONG,
        OpenPgpApi.EXTRA_DETACHED_SIGNATURE to ExtraType.BYTES,
        OpenPgpApi.EXTRA_OPPORTUNISTIC_ENCRYPTION to ExtraType.BOOLEAN,
        OpenPgpApi.EXTRA_SENDER_ADDRESS to ExtraType.TEXT,
        OpenPgpApi.EXTRA_PRESELECT_KEY_ID to ExtraType.LONG,
    )

    val EXTRAS: Set<String> = EXTRA_TYPES.keys

    /** The extra a request screen adds to the Intent it hands back: its request id. */
    const val EXTRA_REQUEST = "com.kemlock.app.mail.REQUEST"

    /**
     * [extras], what a request's Intent held, reduced to the extras Kemlock reads, in the types the
     * channel carries: arrays become lists, except the key IDs (a long array) and bytes.
     */
    fun extras(extras: Map<String, Any?>): Map<String, Any?> = buildMap {
        for ((name, value) in extras) {
            if (name !in EXTRAS) continue
            put(
                name,
                when (value) {
                    is Array<*> -> value.filterIsInstance<String>()
                    is Collection<*> -> value.filterIsInstance<String>()
                    else -> value
                },
            )
        }
    }

    /** One extra of the result Intent, as Dart's answer names it. */
    sealed class Extra(val name: String) {
        class IntValue(name: String, val value: Int) : Extra(name)

        class LongValue(name: String, val value: Long) : Extra(name)

        class LongArrayValue(name: String, val value: LongArray) : Extra(name)

        class BytesValue(name: String, val value: ByteArray) : Extra(name)

        class TextValue(name: String, val value: String) : Extra(name)

        class BoolValue(name: String, val value: Boolean) : Extra(name)

        class Error(val id: Int, val message: String) : Extra(OpenPgpApi.RESULT_ERROR)

        class Signature(
            val result: Int,
            val keyId: Long,
            val primaryUserId: String?,
            val userIds: List<String>,
            val confirmedUserIds: List<String>,
            val senderStatus: String?,
            val timestamp: Long?,
        ) : Extra(OpenPgpApi.RESULT_SIGNATURE)

        class Decryption(val result: Int) : Extra(OpenPgpApi.RESULT_DECRYPTION)

        class Metadata(val filename: String, val mimeType: String?, val modificationTime: Long, val originalSize: Long) :
            Extra(OpenPgpApi.RESULT_METADATA)
    }

    private fun long(value: Any?): Long? = (value as? Number)?.toLong()

    private fun strings(value: Any?): List<String> = (value as? Collection<*>)?.filterIsInstance<String>().orEmpty()

    private fun longs(value: Any?): LongArray = when (value) {
        is LongArray -> value
        is IntArray -> LongArray(value.size) { value[it].toLong() }
        is Collection<*> -> value.filterIsInstance<Number>().map { it.toLong() }.toLongArray()
        else -> LongArray(0)
    }

    /** The result code of Dart's [result]; an error when it has none. */
    fun resultCode(result: Map<String, Any?>): Int = (result[OpenPgpApi.RESULT_CODE] as? Number)?.toInt() ?: OpenPgpApi.RESULT_CODE_ERROR

    /** The extras of Dart's [result] but its result code, as the result Intent carries them. */
    fun resultExtras(result: Map<String, Any?>): List<Extra> = buildList {
        for ((name, value) in result) {
            when (name) {
                OpenPgpApi.RESULT_CODE -> continue
                OpenPgpApi.RESULT_ERROR -> (value as? Map<*, *>)?.let {
                    add(Extra.Error((it["id"] as? Number)?.toInt() ?: OpenPgpError.GENERIC_ERROR, it["message"] as? String ?: ""))
                }
                OpenPgpApi.RESULT_SIGNATURE -> (value as? Map<*, *>)?.let {
                    add(
                        Extra.Signature(
                            result = (it["result"] as? Number)?.toInt() ?: OpenPgpSignatureResult.RESULT_NO_SIGNATURE,
                            keyId = long(it["key_id"]) ?: 0L,
                            primaryUserId = it["primary_user_id"] as? String,
                            userIds = strings(it["user_ids"]),
                            confirmedUserIds = strings(it["confirmed_user_ids"]),
                            senderStatus = it["sender_status"] as? String,
                            timestamp = long(it["timestamp"]),
                        ),
                    )
                }
                OpenPgpApi.RESULT_DECRYPTION -> (value as? Map<*, *>)?.let {
                    add(Extra.Decryption((it["result"] as? Number)?.toInt() ?: OpenPgpDecryptionResult.RESULT_NOT_ENCRYPTED))
                }
                OpenPgpApi.RESULT_METADATA -> (value as? Map<*, *>)?.let {
                    add(
                        Extra.Metadata(
                            filename = it["filename"] as? String ?: "",
                            mimeType = it["mime_type"] as? String,
                            modificationTime = long(it["modification_time"]) ?: 0L,
                            originalSize = long(it["original_size"]) ?: 0L,
                        ),
                    )
                }
                OpenPgpApi.RESULT_KEY_IDS -> add(Extra.LongArrayValue(name, longs(value)))
                OpenPgpApi.RESULT_SIGN_KEY_ID -> long(value)?.let { add(Extra.LongValue(name, it)) }
                OpenPgpApi.RESULT_AUTOCRYPT_STATUS -> (value as? Number)?.let { add(Extra.IntValue(name, it.toInt())) }
                else -> when (value) {
                    is ByteArray -> add(Extra.BytesValue(name, value))
                    is String -> add(Extra.TextValue(name, value))
                    is Boolean -> add(Extra.BoolValue(name, value))
                    is Int -> add(Extra.IntValue(name, value))
                    is Long -> add(Extra.LongValue(name, value))
                }
            }
        }
    }

    /** The extras a request screen's Dart side adds to the request it hands back: `sign_key_id`. */
    fun handBack(extras: Map<String, Any?>): List<Extra> = buildList {
        long(extras[OpenPgpApi.EXTRA_SIGN_KEY_ID])?.let { add(Extra.LongValue(OpenPgpApi.EXTRA_SIGN_KEY_ID, it)) }
    }

    /** A random request id: 128 bits in hexadecimal. */
    fun newId(random: SecureRandom = SecureRandom()): String = PgpCaller.hex(ByteArray(16).also(random::nextBytes))

    /** What a request's input pipe held: its bytes, or that it went over the limit and was not read on. */
    class Input(val bytes: ByteArray?, val tooLarge: Boolean)

    /** The answer of a `dry` call that comes down to the work on the input: Dart wants it. */
    const val SEND_INPUT = "sendInput"

    /**
     * Dart's answer to [request], whose input pipe [read] reads. A request with an input pipe
     * ([hasInput]) is asked first `dry`, without it: only when Dart answers [SEND_INPUT], which
     * takes an open vault and an approved app with nothing left to ask the person, is the input
     * read, and the request asked again with it. So an app the person never approved can't make
     * Kemlock read a byte of its pipe. Null when Dart gave no answer or the input could not be read.
     */
    fun exchange(request: Map<String, Any?>, hasInput: Boolean, ask: (Map<String, Any?>) -> Map<*, *>?, read: () -> Input?): Map<*, *>? {
        if (!hasInput) return ask(request)
        val first = ask(request + ("dry" to true)) ?: return null
        if (first[SEND_INPUT] != true) return first
        val input = read() ?: return null
        return ask(request + mapOf("input" to input.bytes, "inputTooLarge" to input.tooLarge))?.takeIf { it[SEND_INPUT] != true }
    }
}

/**
 * The requests that wait for the person, by request id, in memory: the caller and the original
 * request, so the request screen trusts nothing an intent could forge (decision 3). An id is
 * forgotten once used, and after [lifetimeMillis]; and each calling uid has [perCaller] at most,
 * its oldest forgotten for a new one, so that no app fills Kemlock's memory with requests.
 */
class PendingRequests<T>(
    private val now: () -> Long = System::currentTimeMillis,
    private val lifetimeMillis: Long = 10 * 60 * 1000L,
    private val perCaller: Int = PER_CALLER,
) {
    private class Entry<T>(val at: Long, val caller: Int, val value: T)

    private val waiting = LinkedHashMap<String, Entry<T>>()

    /** Keeps [value] under [id] for [caller], the uid that asked. */
    @Synchronized
    fun put(id: String, caller: Int, value: T) {
        prune()
        val theirs = waiting.entries.filter { it.value.caller == caller }.map { it.key }
        theirs.take((theirs.size - perCaller + 1).coerceAtLeast(0)).forEach(waiting::remove)
        waiting[id] = Entry(now(), caller, value)
    }

    /** The request [id], while it waits. */
    @Synchronized
    fun peek(id: String): T? {
        prune()
        return waiting[id]?.value
    }

    /** The request [id], forgotten. */
    @Synchronized
    fun take(id: String): T? {
        prune()
        return waiting.remove(id)?.value
    }

    private fun prune() {
        val cutoff = now() - lifetimeMillis
        waiting.entries.removeAll { it.value.at < cutoff }
    }

    companion object {
        /** As many as lib/features/mail/mail_handler.dart keeps for one app. */
        const val PER_CALLER = 8
    }
}

/** How many calls each uid has under way, [max] at most, so that no app takes every binder thread. */
class CallerSlots(private val max: Int) {
    private val held = HashMap<Int, Int>()

    /** Takes one of [uid]'s slots; false when it has none left. */
    @Synchronized
    fun take(uid: Int): Boolean {
        val n = held[uid] ?: 0
        if (n >= max) return false
        held[uid] = n + 1
        return true
    }

    @Synchronized
    fun release(uid: Int) {
        val n = (held[uid] ?: return) - 1
        if (n > 0) held[uid] = n else held.remove(uid)
    }
}

/**
 * The write ends of the output pipes apps made, until the `execute` they are for takes them: by
 * the caller's pid and the pipe id it chose, for its uid. Each uid has [perCaller] at most, its
 * oldest closed to make room, and one not taken within [lifetimeMillis] is closed, so that no app
 * leaves Kemlock holding file descriptors it never uses.
 */
class OutputPipes<T>(
    private val close: (T) -> Unit,
    private val now: () -> Long,
    private val lifetimeMillis: Long = 60_000L,
    private val perCaller: Int = 8,
) {
    private class Entry<T>(val uid: Int, val at: Long, val pipe: T)

    private val pipes = LinkedHashMap<Long, Entry<T>>()

    private fun key(pid: Int, pipeId: Int): Long = (pid.toLong() shl 32) or (pipeId.toLong() and 0xffffffffL)

    @Synchronized
    fun put(uid: Int, pid: Int, pipeId: Int, pipe: T) {
        prune()
        pipes.remove(key(pid, pipeId))?.let { close(it.pipe) }
        val theirs = pipes.entries.filter { it.value.uid == uid }.map { it.key }
        theirs.take((theirs.size - perCaller + 1).coerceAtLeast(0)).forEach { pipes.remove(it)?.let { old -> close(old.pipe) } }
        pipes[key(pid, pipeId)] = Entry(uid, now(), pipe)
    }

    /** The pipe [pid] made as [pipeId], if [uid] made it and it is still there. */
    @Synchronized
    fun take(uid: Int, pid: Int, pipeId: Int): T? {
        prune()
        val entry = pipes[key(pid, pipeId)]?.takeIf { it.uid == uid } ?: return null
        pipes.remove(key(pid, pipeId))
        return entry.pipe
    }

    private fun prune() {
        val cutoff = now() - lifetimeMillis
        pipes.entries.filter { it.value.at < cutoff }.forEach {
            pipes.remove(it.key)
            close(it.value.pipe)
        }
    }
}

/** The Android side of [PgpRequest]: Bundles and Intents, with the API's parcelables. */
object PgpIntents {
    /**
     * The extras of [bundle] that Kemlock reads ([PgpRequest.EXTRA_TYPES]) and the request id a
     * request screen added, each asked for by its name and type. Nothing else is taken out: an
     * app that was never approved writes this Bundle, and reading every value of it would make
     * an object of any class the app names. From Android 13 a Bundle makes such an object only
     * when its own key is read, so the rest stays as bytes. Before, the whole Bundle unparcels
     * at the first read, which is why it still gets the app's class loader: the API's own
     * parcelables travel beside these extras.
     */
    fun read(bundle: Bundle?, classLoader: ClassLoader): Map<String, Any?> {
        if (bundle == null) return emptyMap()
        bundle.classLoader = classLoader
        return buildMap {
            for ((name, type) in PgpRequest.EXTRA_TYPES) {
                if (!bundle.containsKey(name)) continue
                // A value of another type reads as null, or as the type's zero, and is no answer to anything
                val value: Any? = when (type) {
                    PgpRequest.ExtraType.INT -> bundle.getInt(name)
                    PgpRequest.ExtraType.BOOLEAN -> bundle.getBoolean(name)
                    PgpRequest.ExtraType.LONG -> bundle.getLong(name)
                    PgpRequest.ExtraType.TEXT -> bundle.getString(name)
                    PgpRequest.ExtraType.TEXTS -> bundle.getStringArray(name)
                    PgpRequest.ExtraType.LONGS -> bundle.getLongArray(name)
                    PgpRequest.ExtraType.BYTES -> bundle.getByteArray(name)
                }
                if (value != null) put(name, value)
            }
            bundle.getString(PgpRequest.EXTRA_REQUEST)?.let { put(PgpRequest.EXTRA_REQUEST, it) }
        }
    }

    fun put(intent: Intent, extra: PgpRequest.Extra) {
        when (extra) {
            is PgpRequest.Extra.IntValue -> intent.putExtra(extra.name, extra.value)
            is PgpRequest.Extra.LongValue -> intent.putExtra(extra.name, extra.value)
            is PgpRequest.Extra.LongArrayValue -> intent.putExtra(extra.name, extra.value)
            is PgpRequest.Extra.BytesValue -> intent.putExtra(extra.name, extra.value)
            is PgpRequest.Extra.TextValue -> intent.putExtra(extra.name, extra.value)
            is PgpRequest.Extra.BoolValue -> intent.putExtra(extra.name, extra.value)
            is PgpRequest.Extra.Error -> intent.putExtra(extra.name, OpenPgpError(extra.id, extra.message))
            is PgpRequest.Extra.Decryption -> intent.putExtra(extra.name, OpenPgpDecryptionResult(extra.result))
            is PgpRequest.Extra.Metadata ->
                intent.putExtra(extra.name, OpenPgpMetadata(extra.filename, extra.mimeType, extra.modificationTime, extra.originalSize))
            is PgpRequest.Extra.Signature -> intent.putExtra(extra.name, signature(extra))
        }
    }

    private fun signature(s: PgpRequest.Extra.Signature): OpenPgpSignatureResult {
        val time = s.timestamp?.let(::Date)
        return when (s.result) {
            OpenPgpSignatureResult.RESULT_NO_SIGNATURE -> OpenPgpSignatureResult.createWithNoSignature()
            OpenPgpSignatureResult.RESULT_KEY_MISSING -> OpenPgpSignatureResult.createWithKeyMissing(s.keyId, time)
            OpenPgpSignatureResult.RESULT_INVALID_SIGNATURE -> OpenPgpSignatureResult.createWithInvalidSignature()
            else -> OpenPgpSignatureResult.createWithValidSignature(
                s.result,
                s.primaryUserId,
                s.keyId,
                s.userIds,
                // Never null: FairEmail reads it of a good signature
                s.confirmedUserIds,
                when (s.senderStatus) {
                    "confirmed" -> OpenPgpSignatureResult.SenderStatusResult.USER_ID_CONFIRMED
                    "unconfirmed" -> OpenPgpSignatureResult.SenderStatusResult.USER_ID_UNCONFIRMED
                    "missing" -> OpenPgpSignatureResult.SenderStatusResult.USER_ID_MISSING
                    // Never null: Thunderbird reads a good signature's sender status with no case for none
                    else -> OpenPgpSignatureResult.SenderStatusResult.UNKNOWN
                },
                time,
            )
        }
    }

    /** The result Intent of Dart's [result]. */
    fun result(result: Map<String, Any?>): Intent = Intent().apply {
        putExtra(OpenPgpApi.RESULT_CODE, PgpRequest.resultCode(result))
        PgpRequest.resultExtras(result).forEach { put(this, it) }
    }

    /** An error result, for what Dart could not answer. */
    fun error(message: String): Intent = Intent().apply {
        putExtra(OpenPgpApi.RESULT_CODE, OpenPgpApi.RESULT_CODE_ERROR)
        putExtra(OpenPgpApi.RESULT_ERROR, OpenPgpError(OpenPgpError.GENERIC_ERROR, message))
    }
}
