package com.kemlock.app.pgp

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** A mail app's pipes, read and written with a deadline (security audit 2026-11-21, M1). */
class MailPipesTest {
    private var now = 0L

    /** An app's input: [chunks] in turn, then its end when it [ends]; with nothing there, a wait runs out, as poll(2)'s does. */
    private inner class Input(chunks: List<ByteArray>, private val ends: Boolean = true) : MailPipes.Pipe {
        private val left = ArrayDeque(chunks)
        var waits = 0

        override fun await(millis: Long): Boolean {
            waits++
            if (left.isEmpty() && !ends) now += millis
            return left.isNotEmpty() || ends
        }

        override fun move(buffer: ByteArray, offset: Int, count: Int): Int {
            val chunk = left.removeFirstOrNull() ?: return -1
            chunk.copyInto(buffer, offset)
            return chunk.size
        }
    }

    /** An app reading its output: [takes] bytes at most, then never again. */
    private inner class Output(private val takes: Int) : MailPipes.Pipe {
        val written = mutableListOf<ByteArray>()
        private val total get() = written.sumOf { it.size }

        override fun await(millis: Long): Boolean {
            if (total >= takes) now += millis
            return total < takes
        }

        override fun move(buffer: ByteArray, offset: Int, count: Int): Int {
            val n = minOf(count, takes - total)
            written += buffer.copyOfRange(offset, offset + n)
            return n
        }
    }

    @Test
    fun readsAPipeToItsEnd() {
        val input = MailPipes.readAll(Input(listOf(byteArrayOf(1, 2), byteArrayOf(3))), limit = 10, deadline = 1000, now = { now })
        assertArrayEquals(byteArrayOf(1, 2, 3), input.bytes)
        assertEquals(false, input.tooLarge)
    }

    @Test
    fun stopsReadingPastTheLimit() {
        val pipe = Input(listOf(ByteArray(6), ByteArray(6), ByteArray(6)))
        val input = MailPipes.readAll(pipe, limit = 10, deadline = 1000, now = { now })
        assertNull(input.bytes)
        assertTrue(input.tooLarge)
        assertEquals("the third piece is never read", 2, pipe.waits)
    }

    @Test
    fun givesUpOnAPipeNeverClosedAtTheDeadline() {
        // Two bytes, then nothing, and the app never closes its end
        try {
            MailPipes.readAll(Input(listOf(byteArrayOf(1, 2)), ends = false), limit = 10, deadline = 1000, now = { now })
            fail("read past the deadline")
        } catch (_: MailPipes.TimedOut) {
            assertEquals(1000L, now)
        }
    }

    @Test
    fun writesAPieceAtATimeAndGivesUpOnAReaderThatStopped() {
        val bytes = ByteArray(10_000) { it.toByte() }
        val reader = Output(takes = bytes.size)
        MailPipes.writeAll(reader, bytes, deadline = 1000, now = { now })
        assertArrayEquals(bytes, reader.written.reduce { a, b -> a + b })
        assertTrue(reader.written.all { it.size <= MailPipes.PIPE_BUF })
        assertEquals(0L, now)
        // An app that reads 5000 bytes, and no more
        val stopped = Output(takes = 5000)
        try {
            MailPipes.writeAll(stopped, bytes, deadline = 1000, now = { now })
            fail("wrote past the deadline")
        } catch (_: MailPipes.TimedOut) {
            assertEquals(5000, stopped.written.sumOf { it.size })
            assertEquals(1000L, now)
        }
    }
}
