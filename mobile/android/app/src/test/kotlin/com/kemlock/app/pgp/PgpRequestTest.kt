package com.kemlock.app.pgp

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A mail app's request on its way to Dart, and the answer back (add-pgp-mail-provider, tasks 7.2 and 7.4). */
class PgpRequestTest {
    @Test
    fun theExtrasOfEachActionLandUnderTheirNames() {
        // Thunderbird's SIGN_AND_ENCRYPT, as its Intent holds them
        val sent = PgpRequest.extras(
            mapOf(
                "api_version" to 12,
                "key_ids" to longArrayOf(42L),
                "user_ids" to arrayOf("ada@example.org", "Charles <charles@example.org>"),
                "sign_key_id" to 42L,
                "ascii_armor" to true,
            ),
        )
        assertEquals(setOf("api_version", "key_ids", "user_ids", "sign_key_id", "ascii_armor"), sent.keys)
        assertEquals(listOf("ada@example.org", "Charles <charles@example.org>"), sent["user_ids"])
        assertEquals(42L, sent["sign_key_id"])
        // Its GET_SIGN_KEY_ID, GET_KEY and DECRYPT_VERIFY
        assertEquals(
            setOf("user_id", "preselect_key_id", "key_id", "sender_address", "detached_signature", "opportunistic"),
            PgpRequest.extras(
                mapOf(
                    "user_id" to "Ada <ada@example.org>",
                    "preselect_key_id" to 7L,
                    "key_id" to 7L,
                    "sender_address" to "ada@example.org",
                    "detached_signature" to byteArrayOf(1, 2),
                    "opportunistic" to true,
                ),
            ).keys,
        )
    }

    @Test
    fun unknownExtrasAndThePassphraseAreDropped() {
        val sent = PgpRequest.extras(
            mapOf(
                "api_version" to 12,
                "passphrase" to "secret".toCharArray(),
                "eu.faircode.email" to mapOf("id" to 1),
                "progress_messenger" to Any(),
                "autocrypt_peer_update" to Any(),
                "decryption_result" to Any(),
            ),
        )
        assertEquals(setOf("api_version"), sent.keys)
    }

    @Test
    fun onlyTheExtrasItKnowsAreAskedOfARequestEachByItsType() {
        // What PgpIntents.read takes out of a Bundle an unapproved app wrote: these names, as these types, and no other
        assertEquals(
            mapOf(
                "api_version" to PgpRequest.ExtraType.INT,
                "ascii_armor" to PgpRequest.ExtraType.BOOLEAN,
                "user_ids" to PgpRequest.ExtraType.TEXTS,
                "key_ids" to PgpRequest.ExtraType.LONGS,
                "sign_key_id" to PgpRequest.ExtraType.LONG,
                "user_id" to PgpRequest.ExtraType.TEXT,
                "key_id" to PgpRequest.ExtraType.LONG,
                "detached_signature" to PgpRequest.ExtraType.BYTES,
                "opportunistic" to PgpRequest.ExtraType.BOOLEAN,
                "sender_address" to PgpRequest.ExtraType.TEXT,
                "preselect_key_id" to PgpRequest.ExtraType.LONG,
            ),
            PgpRequest.EXTRA_TYPES,
        )
        assertEquals(PgpRequest.EXTRA_TYPES.keys, PgpRequest.EXTRAS)
        // Never the passphrase, nor the parcelables the API carries beside them
        for (name in listOf("passphrase", "autocrypt_peer_update", "decryption_result", "progress_messenger")) {
            assertTrue(name, name !in PgpRequest.EXTRA_TYPES)
        }
    }

    @Test
    fun longArraysOfKeyIdsSurvive() {
        val ids = longArrayOf(Long.MIN_VALUE, -2L, 0x5D49D28C8EFC2F98L, Long.MAX_VALUE)
        assertArrayEquals(ids, PgpRequest.extras(mapOf("key_ids" to ids))["key_ids"] as LongArray)
        // And back, from the lists the channel hands over
        val back = PgpRequest.resultExtras(mapOf("result_code" to 1, "key_ids" to listOf(Long.MIN_VALUE, -2, 0x5D49D28C8EFC2F98L, Long.MAX_VALUE)))
        assertArrayEquals(ids, (back.single() as PgpRequest.Extra.LongArrayValue).value)
    }

    @Test
    fun anAnswerBecomesTheResultExtras() {
        val answer = mapOf(
            "result_code" to 1,
            "signature" to mapOf(
                "result" to 1,
                "key_id" to 42,
                "primary_user_id" to "Ada <ada@example.org>",
                "user_ids" to listOf("Ada <ada@example.org>"),
                "confirmed_user_ids" to listOf("Ada <ada@example.org>"),
                "sender_status" to "confirmed",
                "timestamp" to 1794894553000L,
            ),
            "decryption" to mapOf("result" to 1),
            "metadata" to mapOf("filename" to "", "mime_type" to "text/plain", "modification_time" to 0, "original_size" to 162),
            "detached_signature" to byteArrayOf(9),
            "signature_micalg" to "pgp-sha512",
            "keys_confirmed" to true,
            "autocrypt_status" to 2,
            "sign_key_id" to 42,
        )
        assertEquals(1, PgpRequest.resultCode(answer))
        val extras = PgpRequest.resultExtras(answer).associateBy { it.name }
        val signature = extras["signature"] as PgpRequest.Extra.Signature
        assertEquals(1, signature.result)
        assertEquals(42L, signature.keyId)
        assertEquals("confirmed", signature.senderStatus)
        assertEquals(1794894553000L, signature.timestamp)
        assertEquals(1, (extras["decryption"] as PgpRequest.Extra.Decryption).result)
        assertEquals(162L, (extras["metadata"] as PgpRequest.Extra.Metadata).originalSize)
        assertEquals("pgp-sha512", (extras["signature_micalg"] as PgpRequest.Extra.TextValue).value)
        assertTrue((extras["keys_confirmed"] as PgpRequest.Extra.BoolValue).value)
        assertEquals(2, (extras["autocrypt_status"] as PgpRequest.Extra.IntValue).value)
        assertEquals(42L, (extras["sign_key_id"] as PgpRequest.Extra.LongValue).value)
        assertEquals(setOf("signature", "decryption", "metadata", "detached_signature", "signature_micalg", "keys_confirmed", "autocrypt_status", "sign_key_id"), extras.keys)
    }

    @Test
    fun anErrorKeepsItsIdAndMessage() {
        val error = PgpRequest.resultExtras(mapOf("result_code" to 0, "error" to mapOf("id" to 1, "message" to "no"))).single() as PgpRequest.Extra.Error
        assertEquals(1, error.id)
        assertEquals("no", error.message)
        assertEquals(0, PgpRequest.resultCode(mapOf("nothing" to 1)))
    }

    @Test
    fun aScreenHandsBackOnlyTheSigningKey() {
        val back = PgpRequest.handBack(mapOf("sign_key_id" to 42, "other" to 1))
        assertEquals(42L, (back.single() as PgpRequest.Extra.LongValue).value)
    }

    @Test
    fun theTableForgetsAnIdOnceUsedAndAfterTenMinutes() {
        var now = 0L
        val table = PendingRequests<String>(now = { now })
        table.put("a", 10001, "first")
        table.put("b", 10001, "second")
        assertEquals("first", table.peek("a"))
        assertEquals("first", table.take("a"))
        assertNull(table.take("a"))
        assertNull(table.peek("forged"))
        now += 10 * 60 * 1000L
        assertEquals("second", table.peek("b"))
        now += 1
        assertNull(table.peek("b"))
    }

    @Test
    fun anAppKeepsEightRequestsAtMostAndItsOldestGoesFirst() {
        val table = PendingRequests<String>(now = { 0L })
        table.put("tb", 10001, "Thunderbird's")
        for (i in 1..9) table.put("x$i", 10666, "request $i")
        assertNull(table.peek("x1"))
        for (i in 2..9) assertEquals("request $i", table.peek("x$i"))
        assertEquals("another app's is kept", "Thunderbird's", table.peek("tb"))
        assertEquals(8, PendingRequests.PER_CALLER)
    }

    @Test
    fun anAppHasFourCallsUnderWayAtMost() {
        val calls = CallerSlots(4)
        repeat(4) { assertTrue(calls.take(10666)) }
        assertEquals(false, calls.take(10666))
        assertTrue("another app's call goes on", calls.take(10001))
        calls.release(10666)
        assertTrue(calls.take(10666))
        assertEquals(false, calls.take(10666))
        // A release with nothing taken frees nothing more
        repeat(6) { calls.release(10002) }
        assertTrue(calls.take(10002))
    }

    @Test
    fun outputPipesGoToTheAppThatMadeThemAndNoAppHoardsThem() {
        var now = 0L
        val closed = mutableListOf<String>()
        val pipes = OutputPipes<String>(close = { closed += it }, now = { now })
        pipes.put(uid = 10001, pid = 100, pipeId = 1, pipe = "tb-1")
        // Another app's call, under a pid that was Thunderbird's, gets nothing
        assertNull(pipes.take(uid = 10666, pid = 100, pipeId = 1))
        assertEquals("tb-1", pipes.take(uid = 10001, pid = 100, pipeId = 1))
        assertNull(pipes.take(uid = 10001, pid = 100, pipeId = 1))
        // Nine pipes never used: the oldest is closed for the ninth
        for (i in 1..9) pipes.put(uid = 10666, pid = 200 + i, pipeId = 7, pipe = "x$i")
        assertEquals(listOf("x1"), closed)
        assertNull(pipes.take(uid = 10666, pid = 201, pipeId = 7))
        // The same id made again closes the first
        pipes.put(uid = 10666, pid = 209, pipeId = 7, pipe = "x9 again")
        assertEquals(listOf("x1", "x9"), closed)
        // A minute later every one left is closed
        now += 60_001L
        assertNull(pipes.take(uid = 10666, pid = 202, pipeId = 7))
        assertEquals(setOf("x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x9 again"), closed.toSet())
    }

    @Test
    fun theInputIsReadOnlyWhenDartWantsIt() {
        val request = mapOf<String, Any?>("requestId" to "r1", "action" to "org.openintents.openpgp.action.SIGN")
        val asked = mutableListOf<Map<String, Any?>>()
        var reads = 0
        fun exchange(hasInput: Boolean, vararg answers: Map<String, Any?>?): Map<*, *>? {
            asked.clear()
            reads = 0
            val queue = ArrayDeque(answers.toList())
            return PgpRequest.exchange(request, hasInput, ask = { asked += it; queue.removeFirst() }) {
                reads++
                PgpRequest.Input(byteArrayOf(1, 2, 3), tooLarge = false)
            }
        }

        // Locked, or an app never approved: the person is needed, and not a byte is read
        val personNeeded = mapOf("result" to mapOf("result_code" to 2))
        assertEquals(personNeeded, exchange(hasInput = true, personNeeded))
        assertEquals(listOf(request + ("dry" to true)), asked)
        assertEquals(0, reads)
        // Only the work is left: read, and asked again with it
        val signed = mapOf("result" to mapOf("result_code" to 1), "output" to byteArrayOf(9))
        assertEquals(signed, exchange(hasInput = true, mapOf("sendInput" to true), signed))
        assertEquals(1, reads)
        assertEquals(2, asked.size)
        assertTrue("dry" !in asked[1])
        assertArrayEquals(byteArrayOf(1, 2, 3), asked[1]["input"] as ByteArray)
        assertEquals(false, asked[1]["inputTooLarge"])
        // A second call that wants the input again, or no answer, is no answer
        assertNull(exchange(hasInput = true, mapOf("sendInput" to true), mapOf("sendInput" to true)))
        assertNull(exchange(hasInput = true, null))
        assertEquals(0, reads)
        // Without an input pipe, one call as before
        assertEquals(signed, exchange(hasInput = false, signed))
        assertEquals(listOf(request), asked)
        assertEquals(0, reads)
    }

    @Test
    fun anInputThatCannotBeReadIsNoAnswer() {
        var calls = 0
        val answer = PgpRequest.exchange(mapOf("requestId" to "r1"), hasInput = true, ask = { calls++; mapOf("sendInput" to true) }) { null }
        assertNull(answer)
        assertEquals(1, calls)
    }

    @Test
    fun requestIdsAre128RandomBits() {
        val ids = (1..100).map { PgpRequest.newId() }.toSet()
        assertEquals(100, ids.size)
        assertTrue(ids.all { it.length == 32 && it.all { c -> c in "0123456789abcdef" } })
    }
}
