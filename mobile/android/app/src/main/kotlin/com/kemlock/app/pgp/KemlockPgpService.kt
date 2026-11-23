package com.kemlock.app.pgp

import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.net.Uri
import android.os.Binder
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import com.kemlock.app.R
import com.kemlock.app.engine.KemlockEngine
import org.openintents.openpgp.IOpenPgpService2
import org.openintents.openpgp.util.OpenPgpApi
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/**
 * Kemlock as an OpenPGP app for Android mail apps (openspec: add-pgp-mail-provider): the bound
 * service of OpenKeychain's interface, `IOpenPgpService2`, found by its action. It does no
 * cryptography and decides nothing: each `execute` goes to Dart over `com.kemlock.app/mail`, on
 * the main thread while the binder thread waits, and Dart answers with the open vault's keys or
 * says the person is needed. The service then keeps the request in memory under a random id and
 * hands the mail app an immutable, one-shot PendingIntent to [MailRequestActivity], which only the
 * mail app, in front, can start. Kemlock never starts an activity itself.
 *
 * Input is read whole into memory, up to [MAX_INPUT] (decision 10); nothing is written to storage.
 * It is read only once Dart, asked first without it, wants it ([PgpRequest.exchange]).
 * The service is exported with no permission, as OpenKeychain's is: the check is the person's
 * approval of each app, pinned to its certificate (decision 4).
 */
class KemlockPgpService : Service() {
    private val main = Handler(Looper.getMainLooper())

    /** The write ends of the output pipes, until the call they are for. */
    private val pipes = OutputPipes<ParcelFileDescriptor>(close = ::close, now = SystemClock::elapsedRealtime)

    /** The calls under way, [CALLS_PER_CALLER] at most for each app. */
    private val calls = CallerSlots(CALLS_PER_CALLER)

    override fun onCreate() {
        super.onCreate()
        // Dart starts as the first mail app binds, so the first request finds it running
        KemlockEngine.obtain(this)
    }

    override fun onBind(intent: Intent?): IBinder = binder

    private val binder = object : IOpenPgpService2.Stub() {
        override fun createOutputPipe(pipeId: Int): ParcelFileDescriptor? = try {
            val (read, write) = ParcelFileDescriptor.createPipe()
            pipes.put(Binder.getCallingUid(), Binder.getCallingPid(), pipeId, write)
            read
        } catch (_: IOException) {
            null
        }

        override fun execute(data: Intent?, input: ParcelFileDescriptor?, pipeId: Int): Intent {
            val uid = Binder.getCallingUid()
            val output = if (pipeId == 0) null else pipes.take(uid, Binder.getCallingPid(), pipeId)
            if (!calls.take(uid)) {
                close(input)
                close(output)
                return PgpIntents.error(getString(R.string.pgp_error_busy))
            }
            return try {
                when (val caller = PgpCaller.read(this@KemlockPgpService, uid)) {
                    // Never Dart's to answer, so that the answer is the same whether the vault is open or not
                    is PgpCaller.Refused -> PgpIntents.error(getString(R.string.pgp_error_refused))
                    is PgpCaller.Pinned -> answer(data ?: Intent(), input, output, outputAsked = pipeId != 0, uid, caller)
                }
            } catch (_: RuntimeException) {
                PgpIntents.error(getString(R.string.pgp_error_failed))
            } finally {
                calls.release(uid)
                close(input)
                close(output)
            }
        }
    }

    private fun close(fd: ParcelFileDescriptor?) {
        try {
            fd?.close()
        } catch (_: IOException) {
            // Closed already
        }
    }

    private fun read(fd: ParcelFileDescriptor): PgpRequest.Input =
        MailPipes.readAll(MailPipes.pipe(fd.fileDescriptor, write = false), MAX_INPUT, deadline(), SystemClock::elapsedRealtime)

    private fun deadline(): Long = SystemClock.elapsedRealtime() + MailPipes.DEADLINE_MILLIS

    /** Runs [work] on the main thread and waits for it. */
    private fun <T> onMain(work: () -> T): T {
        if (Looper.myLooper() == Looper.getMainLooper()) return work()
        val task = FutureTask(work)
        main.post(task)
        return task.get()
    }

    /** Hands [args] to Dart and waits for its answer; null when there was none in time. */
    private fun ask(channel: MailChannel, args: Map<String, Any?>): Map<*, *>? {
        val done = CountDownLatch(1)
        var answer: Map<*, *>? = null
        main.post {
            channel.execute(args) {
                answer = it
                done.countDown()
            }
        }
        return if (done.await(ANSWER_MINUTES, TimeUnit.MINUTES)) answer else null
    }

    /**
     * Dart's answer to [data], as the result Intent. [outputAsked]: the mail app named an output
     * pipe, which is [output] while it is still there for it.
     */
    private fun answer(
        data: Intent,
        input: ParcelFileDescriptor?,
        output: ParcelFileDescriptor?,
        outputAsked: Boolean,
        uid: Int,
        caller: PgpCaller,
    ): Intent {
        // The API's parcelables, AutocryptPeerUpdate and OpenPgpDecryptionResult among them, read with this app's classes
        val extras = PgpIntents.read(data.extras, classLoader)
        val id = PgpRequest.newId()
        val request = mapOf(
            "requestId" to id,
            "resentFrom" to extras[PgpRequest.EXTRA_REQUEST] as? String,
            "action" to data.action.orEmpty(),
            "extras" to PgpRequest.extras(extras),
            "caller" to caller.toMap(),
        )
        val channel = onMain { KemlockEngine.channels(this).mail }
        if (!channel.ready.await(DART_START_SECONDS, TimeUnit.SECONDS)) return PgpIntents.error(getString(R.string.pgp_error_not_ready))
        // The input is read only once Dart says the work on it is all that is left
        val answer = PgpRequest.exchange(request, hasInput = input != null, ask = { ask(channel, it) }) {
            try {
                read(input!!)
            } catch (_: IOException) {
                null
            }
        }
        @Suppress("UNCHECKED_CAST")
        val result = answer?.get("result") as? Map<String, Any?> ?: return PgpIntents.error(getString(R.string.pgp_error_failed))
        // The output goes before the result is made, so that output not handed over whole makes the result
        // an error, with no signature or decryption result beside it: never a success over part of a message
        val bytes = answer["output"] as? ByteArray
        if (bytes != null && outputAsked && !wroteAll(output, bytes)) return PgpIntents.error(getString(R.string.pgp_error_output))
        val intent = PgpIntents.result(result)
        if (PgpRequest.resultCode(result) == OpenPgpApi.RESULT_CODE_USER_INTERACTION_REQUIRED) {
            pending.put(id, uid, PendingMail(caller, Intent(data)))
            intent.putExtra(OpenPgpApi.RESULT_INTENT, requestScreen(id))
        }
        return intent
    }

    /**
     * Writes [bytes] whole to [output], within the deadline. False when they didn't all go: the pipe
     * was gone (closed for another of the app's, or after a minute unused), or the app stopped
     * reading, or took too long. execute closes the pipe either way.
     */
    private fun wroteAll(output: ParcelFileDescriptor?, bytes: ByteArray): Boolean {
        if (output == null) return false
        return try {
            MailPipes.writeAll(MailPipes.pipe(output.fileDescriptor, write = true), bytes, deadline(), SystemClock::elapsedRealtime)
            true
        } catch (_: IOException) {
            false
        }
    }

    /** The PendingIntent of [id]'s request screen: immutable and one-shot, apart from every other by its data. */
    private fun requestScreen(id: String): PendingIntent {
        val intent = Intent(this, MailRequestActivity::class.java)
            .setData(Uri.parse("kemlock-mail://request/$id"))
            .putExtra(PgpRequest.EXTRA_REQUEST, id)
        return PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT)
    }

    /** A request waiting for the person: who asked, and the Intent it came with, to hand back. */
    class PendingMail(val caller: PgpCaller, val request: Intent)

    companion object {
        /** 50 MB, decision 10's assumption, to correct by what a phone measures. */
        const val MAX_INPUT = 50L * 1024 * 1024

        /** How long a request waits for Dart to start. */
        const val DART_START_SECONDS = 10L

        /** How long it waits for Dart's answer: a large mail to an RSA key takes a while. */
        const val ANSWER_MINUTES = 3L

        /** The calls one app may have under way at once; one more is told Kemlock is busy. */
        const val CALLS_PER_CALLER = 4

        /** The requests waiting for the person, for ten minutes at most, and eight for each app. */
        val pending = PendingRequests<PendingMail>()
    }
}
