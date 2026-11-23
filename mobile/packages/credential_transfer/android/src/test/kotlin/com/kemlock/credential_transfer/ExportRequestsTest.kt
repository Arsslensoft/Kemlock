package com.kemlock.credential_transfer

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The one request that waits for the person, and who answers it (task 8.4). */
class ExportRequestsTest {
    private class Replier : ExportReplier {
        val answers = mutableListOf<String>()
        var refused = 0

        override fun answer(json: String) {
            answers += json
        }

        override fun refuse() {
            refused++
        }
    }

    private fun request(id: String) = PendingExport(id, "main", "com.example.importer", "Importer", setOf("basic-auth"))

    @After
    fun forget() {
        ExportRequests.onRequest = null
        ExportRequests.pending()?.let { ExportRequests.refuse(it.id) }
    }

    @Test
    fun holdsARequestAndTellsDart() {
        val told = mutableListOf<PendingExport>()
        ExportRequests.onRequest = { told += it }
        val replier = Replier()

        ExportRequests.open(request("a"), replier)

        assertEquals("a", ExportRequests.pending()?.id)
        assertEquals(listOf("a"), told.map { it.id })
    }

    @Test
    fun answersOnlyTheRequestItWasAskedFor() {
        val replier = Replier()
        ExportRequests.open(request("a"), replier)

        assertFalse(ExportRequests.answer("b", "{}"))
        assertTrue(replier.answers.isEmpty())

        assertTrue(ExportRequests.answer("a", "{\"x\":1}"))
        assertEquals(listOf("{\"x\":1}"), replier.answers)
        assertNull(ExportRequests.pending())
    }

    @Test
    fun answersOnce() {
        val replier = Replier()
        ExportRequests.open(request("a"), replier)

        assertTrue(ExportRequests.answer("a", "{}"))
        assertFalse(ExportRequests.answer("a", "{}"))

        assertEquals(1, replier.answers.size)
    }

    @Test
    fun aNewerRequestCancelsTheOlder() {
        val first = Replier()
        val second = Replier()
        ExportRequests.open(request("a"), first)

        ExportRequests.open(request("b"), second)

        assertEquals(1, first.refused)
        assertFalse(ExportRequests.answer("a", "{}"))
        assertEquals("b", ExportRequests.pending()?.id)
    }

    @Test
    fun refusingEndsTheRequestWithACancel() {
        val replier = Replier()
        ExportRequests.open(request("a"), replier)

        assertFalse(ExportRequests.refuse("b"))
        assertTrue(ExportRequests.refuse("a"))

        assertEquals(1, replier.refused)
        assertTrue(replier.answers.isEmpty())
        assertNull(ExportRequests.pending())
    }

    @Test
    fun aRequestWhoseActivityEndedIsForgotten() {
        val replier = Replier()
        ExportRequests.open(request("a"), replier)

        ExportRequests.closed(replier)

        assertNull(ExportRequests.pending())
        assertFalse(ExportRequests.answer("a", "{}"))
    }

    @Test
    fun anotherActivityEndingLeavesTheRequestAlone() {
        ExportRequests.open(request("a"), Replier())

        ExportRequests.closed(Replier())

        assertEquals("a", ExportRequests.pending()?.id)
    }

    @Test
    fun saysNothingOfTheDataWhenPrinted() {
        assertEquals("PendingExport(com.example.importer)", request("a").toString())
    }
}
