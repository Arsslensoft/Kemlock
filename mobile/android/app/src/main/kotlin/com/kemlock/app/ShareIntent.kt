package com.kemlock.app

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.security.SecureRandom

/** What a share hands the app: a piece of text, one file, or nothing it takes. */
enum class ShareKind { TEXT, FILE, NOTHING }

/** Why a shared file was not taken, as lib/platform/shared_items.dart names it. */
enum class ShareProblem(val code: String) {
    UNREADABLE("unreadable"),
    NO_ROOM("noRoom"),
}

/** What copying a shared file gave. */
sealed class ShareCopy {
    data class Copied(val file: File, val size: Long) : ShareCopy()

    data class Failed(val problem: ShareProblem) : ShareCopy()
}

/**
 * The parts of taking a share (openspec: add-share-extension, decision 5) that need none of
 * Android's types, so the JVM tests check them, as Callers.kt keeps its checks: what an
 * `ACTION_SEND` intent carries, which streams are taken, and the copy into the app's cache.
 */
object ShareIntent {
    const val ACTION_SEND = "android.intent.action.SEND"

    /** `Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`. */
    const val FLAG_LAUNCHED_FROM_HISTORY = 0x00100000

    /**
     * Whether an intent with [flags] reopened the activity from the recent apps, which hand it
     * the intent it was first started with, share and all, once more: such a share is not taken
     * again.
     */
    fun reopened(flags: Int): Boolean = flags and FLAG_LAUNCHED_FROM_HISTORY != 0

    /**
     * What an intent with [action], the text of `EXTRA_TEXT` and the stream of `EXTRA_STREAM`
     * carries. A stream wins over a text: an app that shares a file often adds a line about it.
     */
    fun kind(action: String?, text: CharSequence?, stream: Any?): ShareKind = when {
        action != ACTION_SEND -> ShareKind.NOTHING
        stream != null -> ShareKind.FILE
        !text.isNullOrEmpty() -> ShareKind.TEXT
        else -> ShareKind.NOTHING
    }

    /**
     * Whether a stream at a URI with [scheme], served by the app of [providerPackage], may be
     * read: a `content` URI of another app only. A `file` URI, or one of this app's own
     * providers, could name the app's private files, such as the vault's storage.
     */
    fun mayRead(scheme: String?, providerPackage: String?, ownPackage: String): Boolean =
        scheme.equals("content", ignoreCase = true) && providerPackage != ownPackage

    /**
     * The provider a URI's [authority] names, which is what to look its app up by. Android lets
     * an authority carry a user in front, `0@com.kemlock.app.flutter.image_provider`, as a share
     * from a work profile has, and takes it off before it opens the provider. Looked up whole,
     * such an authority is no provider at all, and one of this app's own would pass for
     * another app's.
     */
    fun providerAuthority(authority: String?): String? = authority?.substringAfterLast('@')

    /**
     * The name a shared file is kept under: the name the other app gave, reduced to its last
     * part, without control characters, and `shared` when nothing is left.
     */
    fun safeName(name: String?): String {
        val base = name.orEmpty().substringAfterLast('/').substringAfterLast('\\')
        val clean = base.filter { it >= ' ' && it != '\u007f' }.trim()
        return if (clean.isEmpty() || clean == "." || clean == "..") "shared" else clean.take(200)
    }

    /**
     * Copies [input] as [name] into a new directory with a random name under [root], in
     * pieces, and gives the file and its size. A stream that fails halfway, or a phone that
     * runs out of room, leaves neither the file nor its directory.
     */
    fun copy(input: InputStream, root: File, name: String, random: () -> String = ::randomName): ShareCopy {
        val directory = File(root, random())
        val file = File(directory, safeName(name))
        var size = 0L
        try {
            if (!directory.mkdirs()) return ShareCopy.Failed(ShareProblem.NO_ROOM)
            file.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = try {
                        input.read(buffer)
                    } catch (e: IOException) {
                        throw ReadFailed(e)
                    }
                    if (read < 0) break
                    output.write(buffer, 0, read)
                    size += read
                }
                output.fd.sync()
            }
            return ShareCopy.Copied(file, size)
        } catch (e: ReadFailed) {
            directory.deleteRecursively()
            return ShareCopy.Failed(ShareProblem.UNREADABLE)
        } catch (e: IOException) {
            directory.deleteRecursively()
            return ShareCopy.Failed(if (noRoom(e)) ShareProblem.NO_ROOM else ShareProblem.UNREADABLE)
        } catch (e: SecurityException) {
            directory.deleteRecursively()
            return ShareCopy.Failed(ShareProblem.UNREADABLE)
        }
    }

    /** Whether writing failed because the storage is full (`ENOSPC`). */
    fun noRoom(e: IOException): Boolean {
        var cause: Throwable? = e
        while (cause != null) {
            val message = cause.message.orEmpty()
            if (message.contains("ENOSPC") || message.contains("No space left", ignoreCase = true)) return true
            cause = cause.cause
        }
        return false
    }

    private class ReadFailed(cause: IOException) : IOException(cause)

    private val secure = SecureRandom()

    private fun randomName(): String {
        val bytes = ByteArray(8)
        secure.nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }
}

/**
 * How shares reach Dart (openspec: add-share-extension, decision 5), on the process's one engine
 * (`KemlockEngine`, openspec: add-pgp-mail-provider, decision 1), which outlives its activities.
 * Dart asks once, at its start, for the share the app was opened with, and that start may be long
 * past when an activity is made: a mail app may have started the engine, or a share may start a
 * second `MainActivity` in the sending app's task. So a share is the answer to that question
 * while Dart has not asked yet, and is pushed with [push] once it has, whether an activity was
 * opened with it or handed it while it lived. A file still being copied when Dart asks is the
 * answer once it is copied. Main thread only; free of Android types, so the JVM tests check it.
 */
class ShareHandOver<T : Any>(private val push: (T) -> Unit) {
    /** What waits for Dart's question; the newest share wins. */
    private var initial: T? = null

    /** Dart asked while a file was still being copied: answered once it is. */
    private var waiting: ((T?) -> Unit)? = null
    private var copying = 0
    private var asked = false

    /** Dart's `initial` call: [answer] gets the share that waits, or null, and it waits no more. */
    fun asked(answer: (T?) -> Unit) {
        asked = true
        if (initial == null && copying > 0) {
            waiting = answer
        } else {
            answer(initial)
            initial = null
        }
    }

    /** A shared file is being copied; [copied] follows with what that gave. */
    fun copying() {
        copying++
    }

    fun copied(item: T) {
        copying--
        ready(item)
    }

    /** A share, or the reason one was refused, is ready to hand over. */
    fun ready(item: T) {
        val asking = waiting
        when {
            asking != null -> {
                waiting = null
                asking(item)
            }
            asked -> push(item)
            else -> initial = item
        }
    }
}
