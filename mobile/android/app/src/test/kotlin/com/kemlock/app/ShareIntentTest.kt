package com.kemlock.app

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files

class ShareIntentTest {
    private val root: File = Files.createTempDirectory("share").toFile()

    @After
    fun deleteRoot() {
        root.deleteRecursively()
    }

    private val send = ShareIntent.ACTION_SEND
    private val uri = Any()

    @Test
    fun takesATextAlone() {
        assertEquals(ShareKind.TEXT, ShareIntent.kind(send, "Meet me at nine.", null))
    }

    @Test
    fun takesAStreamAlone() {
        assertEquals(ShareKind.FILE, ShareIntent.kind(send, null, uri))
    }

    @Test
    fun takesTheStreamWhenBothAreThere() {
        assertEquals(ShareKind.FILE, ShareIntent.kind(send, "Here is the contract", uri))
    }

    @Test
    fun takesNothingWithNeither() {
        assertEquals(ShareKind.NOTHING, ShareIntent.kind(send, null, null))
        assertEquals(ShareKind.NOTHING, ShareIntent.kind(send, "", null))
        // The launcher, a set-up link, and several files at once
        assertEquals(ShareKind.NOTHING, ShareIntent.kind("android.intent.action.MAIN", null, null))
        assertEquals(ShareKind.NOTHING, ShareIntent.kind("android.intent.action.VIEW", "otpauth://totp/x", null))
        assertEquals(ShareKind.NOTHING, ShareIntent.kind("android.intent.action.SEND_MULTIPLE", null, uri))
        assertEquals(ShareKind.NOTHING, ShareIntent.kind(null, "text", uri))
    }

    @Test
    fun readsContentOfOtherAppsOnly() {
        assertTrue(ShareIntent.mayRead("content", "com.example.mail", "com.kemlock.app"))
        assertTrue(ShareIntent.mayRead("content", null, "com.kemlock.app"))
        // A file URI, or one of this app's own providers, could name the vault's storage
        assertFalse(ShareIntent.mayRead("file", null, "com.kemlock.app"))
        assertFalse(ShareIntent.mayRead("content", "com.kemlock.app", "com.kemlock.app"))
        assertFalse(ShareIntent.mayRead(null, null, "com.kemlock.app"))
    }

    @Test
    fun looksAProviderUpWithoutTheUserInFrontOfIt() {
        // Android opens 0@authority as authority: looked up whole, this app's own provider would be nobody's
        assertEquals("com.kemlock.app.flutter.image_provider", ShareIntent.providerAuthority("0@com.kemlock.app.flutter.image_provider"))
        assertEquals("com.kemlock.app.flutter.image_provider", ShareIntent.providerAuthority("x@10@com.kemlock.app.flutter.image_provider"))
        // A share from a work profile names the other profile's provider this way
        assertEquals("media", ShareIntent.providerAuthority("10@media"))
        assertEquals("com.example.mail.files", ShareIntent.providerAuthority("com.example.mail.files"))
        assertEquals(null, ShareIntent.providerAuthority(null))
    }

    @Test
    fun copiesAStreamUnderANameStrippedOfPathSeparators() {
        val bytes = ByteArray(200_000) { (it * 31).toByte() }

        val copy = ShareIntent.copy(ByteArrayInputStream(bytes), root, "../../shared_prefs/contract.pdf") { "ab12" }

        copy as ShareCopy.Copied
        assertEquals("contract.pdf", copy.file.name)
        assertEquals(File(root, "ab12").canonicalPath, copy.file.parentFile!!.canonicalPath)
        assertArrayEquals(bytes, copy.file.readBytes())
        assertEquals(bytes.size.toLong(), copy.size)
        assertEquals("contract.pdf", ShareIntent.safeName("C:\\Users\\ada\\contract.pdf"))
    }

    @Test
    fun namesAFileWithNoUsableNameShared() {
        assertEquals("shared", ShareIntent.safeName(null))
        assertEquals("shared", ShareIntent.safeName(""))
        assertEquals("shared", ShareIntent.safeName("folder/"))
        assertEquals("shared", ShareIntent.safeName(".."))
        assertEquals("report.txt", ShareIntent.safeName("rep\u0000ort\n.txt"))
    }

    @Test
    fun leavesNoFileWhenTheStreamFailsHalfway() {
        val failing = object : InputStream() {
            private var given = 0

            override fun read(): Int = throw IOException("withdrawn")

            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (given >= 100_000) throw IOException("The other app withdrew the file")
                given += len
                b.fill(7, off, off + len)
                return len
            }
        }

        val copy = ShareIntent.copy(failing, root, "contract.pdf") { "ab12" }

        assertEquals(ShareCopy.Failed(ShareProblem.UNREADABLE), copy)
        assertEquals(emptyList<File>(), root.walk().filter { it != root }.toList())
    }

    @Test
    fun tellsAFullPhoneFromOtherFailures() {
        assertTrue(ShareIntent.noRoom(IOException("write failed: ENOSPC (No space left on device)")))
        assertTrue(ShareIntent.noRoom(IOException("copy", IOException("No space left on device"))))
        assertFalse(ShareIntent.noRoom(IOException("Permission denied")))
        assertEquals("noRoom", ShareProblem.NO_ROOM.code)
        assertEquals("unreadable", ShareProblem.UNREADABLE.code)
    }

    /** Dart on the process's one engine: what it got pushed, and its answers to `initial`. */
    private class Dart {
        val pushed = mutableListOf<String>()
        val answers = mutableListOf<String?>()
        val handOver = ShareHandOver<String> { pushed += it }

        fun ask() = handOver.asked { answers += it }
    }

    @Test
    fun aShareTheAppOpensWithAnswersDartsFirstQuestionOnce() {
        val dart = Dart()
        // MainActivity's onCreate, before Dart has asked
        dart.handOver.ready("Meet me at nine.")

        dart.ask()
        dart.ask()

        assertEquals(listOf("Meet me at nine.", null), dart.answers)
        assertEquals(emptyList<String>(), dart.pushed)
    }

    @Test
    fun aShareOpenedOrHandedOverOnceDartHasAskedIsPushed() {
        // Dart started long before: for a mail app, or for an earlier MainActivity
        val dart = Dart()
        dart.ask()

        // A new MainActivity made with a share, in the sending app's task, then one handed to it in onNewIntent
        dart.handOver.ready("opened")
        dart.handOver.ready("arrived")

        assertEquals(listOf<String?>(null), dart.answers)
        assertEquals(listOf("opened", "arrived"), dart.pushed)
    }

    @Test
    fun theNewestShareWaitsForDart() {
        val dart = Dart()
        dart.handOver.ready("first")
        dart.handOver.ready("second")

        dart.ask()

        assertEquals(listOf<String?>("second"), dart.answers)
        assertEquals(emptyList<String>(), dart.pushed)
    }

    @Test
    fun aFileStillBeingCopiedWhenDartAsksIsTheAnswerOnceCopied() {
        val dart = Dart()
        dart.handOver.copying()

        dart.ask()
        assertEquals(emptyList<String?>(), dart.answers)
        dart.handOver.copied("contract.pdf")
        assertEquals(listOf<String?>("contract.pdf"), dart.answers)

        // A file shared afterwards is pushed once copied
        dart.handOver.copying()
        dart.handOver.copied("invoice.pdf")
        assertEquals(listOf("invoice.pdf"), dart.pushed)
    }

    @Test
    fun anActivityReopenedFromTheRecentAppsTakesNoShareAgain() {
        assertEquals(android.content.Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY, ShareIntent.FLAG_LAUNCHED_FROM_HISTORY)
        // FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY, alone and with FLAG_ACTIVITY_NEW_TASK
        assertTrue(ShareIntent.reopened(0x00100000))
        assertTrue(ShareIntent.reopened(0x10100000))
        // Nothing, FLAG_ACTIVITY_NEW_TASK, FLAG_GRANT_READ_URI_PERMISSION: a share from another app
        assertFalse(ShareIntent.reopened(0))
        assertFalse(ShareIntent.reopened(0x10000000))
        assertFalse(ShareIntent.reopened(0x00000001))
    }

    @Test
    fun aShareOrALinkFromAnotherAppOpensInKemlocksOwnTask() {
        // Read from the sources: the unit tests run in the module's folder
        val manifest = File("src/main/AndroidManifest.xml").readText()
        val main = Regex("""<activity\s+android:name="\.MainActivity"[^>]*>""").find(manifest)!!.value
        assertTrue(main, main.contains("""android:launchMode="singleTask""""))
        assertTrue(main, main.contains("""android:taskAffinity="""""))
    }
}
