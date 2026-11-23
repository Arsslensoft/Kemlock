package com.kemlock.app.pgp

import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import java.io.ByteArrayOutputStream
import java.io.FileDescriptor
import java.io.IOException

/**
 * A mail app's input and output pipes, read and written with a deadline (security audit
 * 2026-11-21). The app holds the other end of each: an input pipe it never closes, or an output
 * pipe it never reads, would hold the binder thread of its call for good, and enough of them
 * every binder thread Kemlock has. So nothing here blocks: each step waits for its pipe with
 * poll(2), no longer than the deadline leaves, then moves only what the pipe has ready.
 */
object MailPipes {
    /** How long a request's input may take to come in whole, and its output to go out. */
    const val DEADLINE_MILLIS = 60_000L

    /**
     * The most written at once: a pipe that poll(2) says takes more takes at least this much
     * without blocking.
     */
    const val PIPE_BUF = 4096

    /** One end of a pipe, as [readAll] and [writeAll] use it; the JVM tests make their own. */
    interface Pipe {
        /** Waits up to [millis] for the pipe to be ready; false when it wasn't, or the wait was cut short. */
        fun await(millis: Long): Boolean

        /**
         * Reads into, or writes from, [count] bytes of [buffer] at [offset], without blocking once
         * [await] said yes: how many moved, 0 when none could, and -1 at the end of an input.
         */
        fun move(buffer: ByteArray, offset: Int, count: Int): Int
    }

    class TimedOut : IOException("The mail app's pipe took too long")

    /**
     * Reads [pipe] to its end, and no further than [limit] bytes, past which the input is too
     * large; throws [TimedOut] when it hasn't ended by [deadline], on [now]'s clock.
     */
    fun readAll(pipe: Pipe, limit: Long, deadline: Long, now: () -> Long): PgpRequest.Input {
        val out = ByteArrayOutputStream()
        val piece = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val left = deadline - now()
            if (left <= 0) throw TimedOut()
            if (!pipe.await(left)) continue
            val n = pipe.move(piece, 0, piece.size)
            if (n < 0) return PgpRequest.Input(out.toByteArray(), tooLarge = false)
            total += n
            // Read no further: the mail app's writer gets a broken pipe
            if (total > limit) return PgpRequest.Input(null, tooLarge = true)
            out.write(piece, 0, n)
        }
    }

    /** Writes [bytes] to [pipe], [PIPE_BUF] at most at a time; throws [TimedOut] when not done by [deadline]. */
    fun writeAll(pipe: Pipe, bytes: ByteArray, deadline: Long, now: () -> Long) {
        var offset = 0
        while (offset < bytes.size) {
            val left = deadline - now()
            if (left <= 0) throw TimedOut()
            if (!pipe.await(left)) continue
            offset += pipe.move(bytes, offset, minOf(PIPE_BUF, bytes.size - offset)).coerceAtLeast(0)
        }
    }

    /** [fd] as a [Pipe]: the read end of an input when not [write], the write end of an output when [write]. */
    fun pipe(fd: FileDescriptor, write: Boolean): Pipe = object : Pipe {
        override fun await(millis: Long): Boolean {
            val wanted = if (write) OsConstants.POLLOUT else OsConstants.POLLIN
            val poll = StructPollfd().apply {
                this.fd = fd
                events = wanted.toShort()
            }
            return try {
                // Ready, or at its end or broken, which the next move says without blocking
                Os.poll(arrayOf(poll), millis.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()) > 0 && poll.revents.toInt() != 0
            } catch (e: ErrnoException) {
                if (e.errno == OsConstants.EINTR) false else throw IOException(e)
            }
        }

        override fun move(buffer: ByteArray, offset: Int, count: Int): Int = try {
            if (write) {
                Os.write(fd, buffer, offset, count)
            } else {
                // read(2) says 0 at the end
                Os.read(fd, buffer, offset, count).let { if (it == 0) -1 else it }
            }
        } catch (e: ErrnoException) {
            // An app may make its end non-blocking: nothing there yet
            if (e.errno == OsConstants.EAGAIN || e.errno == OsConstants.EINTR) 0 else throw IOException(e)
        }
    }
}
