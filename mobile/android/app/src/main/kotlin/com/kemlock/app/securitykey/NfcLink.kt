package com.kemlock.app.securitykey

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.TagLostException
import android.nfc.tech.IsoDep
import android.os.Bundle
import android.os.Handler
import android.os.SystemClock
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * A key held to the phone: its ISO-DEP side, under the name [id] the Dart side knows it by.
 * The name is a counter, never the tag's own identifier.
 */
internal class NfcLink(val id: String, val isoDep: IsoDep, val extendedLength: Boolean) {
    /** The key left the field, or another took its place. Set on the main thread. */
    @Volatile
    var lost = false

    /** How many times the app closed the link, so an exchange cut short by a close can tell. */
    @Volatile
    var closes = 0

    /** An APDU is on its way. */
    @Volatile
    var busy = false

    /** The check that the key is still there. */
    var presence: ScheduledFuture<*>? = null
}

/**
 * Security keys over NFC. While the Dart side listens and the activity is resumed, the phone
 * is in reader mode for ISO 14443 A and B tags with the NDEF check skipped, so a key's NDEF
 * link does not open the browser meanwhile. A tag that speaks ISO-DEP is told as `arrived`;
 * any other is ignored. One key at a time: a new one takes the place of the old.
 *
 * Presence: reader mode has no "tag left" callback, so the key is kept connected and every
 * [PRESENCE_MS] the I/O thread asks `IsoDep.isConnected`, which asks the NFC service whether
 * the tag is still in the field. After the app closed the link the same check connects again,
 * and a connect that fails means the key has left. An exchange that throws
 * [TagLostException] says so at once.
 *
 * All I/O with the tag runs on one thread; answers and events go out on the main thread, where
 * [current] and the listening state live.
 */
internal class NfcLinks(
    private val activity: Activity,
    private val main: Handler,
    private val tell: (Map<String, Any?>) -> Unit,
) : NfcAdapter.ReaderCallback {
    private val adapter: NfcAdapter? = runCatching { NfcAdapter.getDefaultAdapter(activity) }.getOrNull()
    private val io = Executors.newSingleThreadScheduledExecutor()

    /** Closes a link while the I/O thread waits for an answer, which ends the wait. */
    private val closer = Executors.newSingleThreadExecutor()

    private var listening = false
    private var resumed = false
    private var reading = false
    private var counter = 0
    private var current: NfcLink? = null

    /** NFC turned on or off in the system's settings while the search runs. */
    private val adapterState = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.getIntExtra(NfcAdapter.EXTRA_ADAPTER_STATE, NfcAdapter.STATE_OFF)) {
                NfcAdapter.STATE_ON -> {
                    reading = false
                    sync()
                }
                NfcAdapter.STATE_OFF, NfcAdapter.STATE_TURNING_OFF -> {
                    reading = false
                    current?.let(::lose)
                }
            }
        }
    }

    /** The Dart side started or stopped listening for keys. */
    fun listen(on: Boolean) {
        if (listening == on) return
        listening = on
        if (adapter != null) {
            runCatching {
                if (on) {
                    ContextCompat.registerReceiver(
                        activity,
                        adapterState,
                        IntentFilter(NfcAdapter.ACTION_ADAPTER_STATE_CHANGED),
                        ContextCompat.RECEIVER_NOT_EXPORTED,
                    )
                } else {
                    activity.unregisterReceiver(adapterState)
                }
            }
        }
        sync()
    }

    /** The activity came to the front, or left it. */
    fun resumed(on: Boolean) {
        resumed = on
        sync()
    }

    /** The activity is going away for good. */
    fun shutDown() {
        listen(false)
        resumed = false
        sync()
        io.shutdown()
        closer.shutdown()
    }

    /** Reader mode is on exactly while the stream is listened to and the activity is resumed. */
    private fun sync() {
        val adapter = adapter ?: return
        val wanted = listening && resumed
        if (wanted == reading) return
        if (wanted) {
            val extras = Bundle().apply { putInt(NfcAdapter.EXTRA_READER_PRESENCE_CHECK_DELAY, PRESENCE_CHECK_DELAY_MS) }
            reading = runCatching { adapter.enableReaderMode(activity, this, READER_FLAGS, extras) }.isSuccess
        } else {
            runCatching { adapter.disableReaderMode(activity) }
            reading = false
            // Out of reader mode the tag is the system's again.
            current?.let(::lose)
        }
    }

    /** Reader mode found a tag. Runs on a thread of the NFC service's. */
    override fun onTagDiscovered(tag: Tag?) {
        val isoDep = tag?.let { runCatching { IsoDep.get(it) }.getOrNull() } ?: return
        val extended = runCatching { isoDep.isExtendedLengthApduSupported }.getOrDefault(false)
        main.post { arrived(isoDep, extended) }
    }

    private fun arrived(isoDep: IsoDep, extended: Boolean) {
        if (!listening || io.isShutdown) return
        current?.let(::lose)
        counter += 1
        val link = NfcLink("$PREFIX$counter", isoDep, extended)
        current = link
        tell(
            mapOf(
                "event" to "arrived",
                "device" to link.id,
                "product" to null,
                "needsPermission" to false,
                "links" to listOf(mapOf("id" to link.id, "kind" to "nfc", "extendedLength" to extended, "frameSize" to 0)),
            ),
        )
        link.presence = io.scheduleWithFixedDelay({ check(link) }, 0, PRESENCE_MS, TimeUnit.MILLISECONDS)
    }

    /** On the I/O thread: tells the key gone when it no longer answers the presence check. */
    private fun check(link: NfcLink) {
        if (link.lost) return
        val present = runCatching {
            if (!link.isoDep.isConnected) link.isoDep.connect()
            true
        }.getOrDefault(false)
        if (!present) main.post { lose(link) }
    }

    /** The key [link] is gone: says so once, and lets go of the tag. Main thread. */
    private fun lose(link: NfcLink) {
        if (link.lost) return
        link.lost = true
        link.presence?.cancel(false)
        if (current === link) current = null
        tell(mapOf("event" to "left", "device" to link.id))
        if (!closer.isShutdown) closer.execute { runCatching { link.isoDep.close() } }
    }

    private fun find(id: String): NfcLink? = current?.takeIf { it.id == id && !it.lost }

    /** Connects to the key's ISO-DEP side, if the presence check has not already. */
    fun open(id: String, result: MethodChannel.Result) {
        val link = find(id) ?: return result.fail(SecurityKeyError.Removed())
        io.execute {
            try {
                if (!link.isoDep.isConnected) link.isoDep.connect()
                main.post { result.success(null) }
            } catch (e: Exception) {
                answer(link, result, failure(link, e, link.closes, 0, Int.MAX_VALUE))
            }
        }
    }

    /**
     * Ends the link. The tag is closed for real, which also ends an exchange that is waiting
     * for the key; the presence check connects again afterwards.
     */
    fun close(id: String, result: MethodChannel.Result) {
        val link = find(id)
        if (link != null) {
            link.closes += 1
            // From another thread when an APDU is on its way, since the I/O thread is waiting on it.
            if (link.busy) closer.execute { runCatching { link.isoDep.close() } }
            // And in the I/O thread's own order, so an open that follows finds the link closed first.
            io.execute { runCatching { link.isoDep.close() } }
        }
        result.success(null)
    }

    /** One APDU out, one back, waiting [timeoutMs] at most. */
    fun transceive(id: String, data: ByteArray, timeoutMs: Int, result: MethodChannel.Result) {
        val link = find(id) ?: return result.fail(SecurityKeyError.Removed())
        val closes = link.closes
        io.execute {
            val started = SystemClock.elapsedRealtime()
            link.busy = true
            try {
                if (timeoutMs > 0) runCatching { link.isoDep.timeout = timeoutMs }
                val response = link.isoDep.transceive(data)
                link.busy = false
                main.post { result.success(response) }
            } catch (e: Exception) {
                link.busy = false
                answer(link, result, failure(link, e, closes, SystemClock.elapsedRealtime() - started, timeoutMs))
            }
        }
    }

    /**
     * What an exchange that threw [e] means. Android has no exception of its own for a key
     * that is there and silent: it is an [IOException] like any other, so it is read as a
     * timeout when the tag is still connected and the wait lasted about [timeoutMs].
     */
    private fun failure(link: NfcLink, e: Exception, closes: Int, elapsedMs: Long, timeoutMs: Int): SecurityKeyError = when {
        link.closes != closes -> SecurityKeyError.Cancelled()
        link.lost -> SecurityKeyError.Removed()
        e is TagLostException -> SecurityKeyError.Removed()
        // The tag is out of date: another one was found, or reader mode ended.
        e is SecurityException -> SecurityKeyError.Removed()
        e is IOException -> when {
            !runCatching { link.isoDep.isConnected }.getOrDefault(false) -> SecurityKeyError.Removed()
            timeoutMs > 0 && elapsedMs >= timeoutMs - TIMEOUT_SLACK_MS -> SecurityKeyError.Timeout()
            else -> SecurityKeyError.Failed(e.message ?: "The key did not take the message")
        }
        e is IllegalStateException -> SecurityKeyError.Failed("The link is not open")
        else -> SecurityKeyError.Failed(e.message ?: e.javaClass.simpleName)
    }

    private fun answer(link: NfcLink, result: MethodChannel.Result, error: SecurityKeyError) {
        main.post {
            result.fail(error)
            if (error is SecurityKeyError.Removed) lose(link)
        }
    }

    companion object {
        private const val PREFIX = "nfc:"
        private const val READER_FLAGS =
            NfcAdapter.FLAG_READER_NFC_A or NfcAdapter.FLAG_READER_NFC_B or NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK

        /** How often the NFC service itself checks that the tag is there, in reader mode. */
        private const val PRESENCE_CHECK_DELAY_MS = 300

        /** How often this class asks it. */
        private const val PRESENCE_MS = 500L

        /** An exchange that failed this close to its time limit is taken to have run out of it. */
        private const val TIMEOUT_SLACK_MS = 100L

        /** Whether the link named [id] is an NFC one. */
        fun owns(id: String): Boolean = id.startsWith(PREFIX)
    }
}
