package com.kemlock.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * Hands what other apps share to lib/platform/shared_items.dart (openspec: add-share-extension,
 * decision 5): the share the app was opened with, asked for once, and those that arrive while
 * it runs. A text is handed over as it is and kept in memory only. A file is copied, off the
 * main thread, into `<cache>/share/<random>/<name>`, which only this app can read and Android's
 * backups leave out, and its path is handed over: the other app's URI can be read only while
 * the activity it was shared to lives, and the PGP sheets read a file by its path, in pieces.
 * Dart deletes the copy when it is used, dropped or ten minutes old.
 *
 * It belongs to the process's engine (`KemlockEngine`), not to an activity, as the set-up links
 * do (openspec: add-pgp-mail-provider, decision 1): the engine may have started without an
 * activity, for a mail app, and Dart asks for the first share only once ([ShareHandOver]).
 * [context] is the application's.
 */
class ShareChannel(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.kemlock.app/share")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val handOver = ShareHandOver<Map<String, Any?>> { channel.invokeMethod("item", it) }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "initial" -> handOver.asked { result.success(it) }
                // Nothing of a share is kept outside the cache directory, which Dart empties
                "clear" -> result.success(null)
                else -> result.notImplemented()
            }
        }
    }

    /**
     * The intent an activity was made with. An activity Android made again with its saved state
     * took its share when it was first made, and is not to call this.
     */
    fun opened(intent: Intent?) = take(intent)

    /** An intent handed to a living activity. */
    fun arrived(intent: Intent) = take(intent)

    /** Takes [intent] when it is a share. */
    private fun take(intent: Intent?) {
        if (intent == null) return
        // Opened again from the recent apps, the activity gets the share it was started with once more
        if (ShareIntent.reopened(intent.flags)) return
        val stream = streamOf(intent)
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)
        when (ShareIntent.kind(intent.action, text, stream)) {
            ShareKind.NOTHING -> return
            ShareKind.TEXT -> handOver.ready(mapOf("text" to text.toString()))
            ShareKind.FILE -> {
                val uri = stream ?: return
                val type = intent.type
                handOver.copying()
                worker.execute {
                    val handed = copy(uri, type)
                    main.post { handOver.copied(handed) }
                }
            }
        }
    }

    private fun streamOf(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    /** Copies the file at [uri] into the cache; what to hand Dart, or why it was refused. */
    private fun copy(uri: Uri, type: String?): Map<String, Any?> {
        val resolver = context.contentResolver
        @Suppress("DEPRECATION")
        val provider = ShareIntent.providerAuthority(uri.authority)?.let { context.packageManager.resolveContentProvider(it, 0)?.packageName }
        if (!ShareIntent.mayRead(uri.scheme, provider, context.packageName)) return refused(ShareProblem.UNREADABLE)
        var name: String? = null
        try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) name = cursor.getString(0)
            }
        } catch (e: Exception) {
            // The name is a courtesy; the URI's last part will do
        }
        val input = try {
            resolver.openInputStream(uri)
        } catch (e: Exception) {
            null
        } ?: return refused(ShareProblem.UNREADABLE)
        val copied = input.use { ShareIntent.copy(it, File(context.cacheDir, "share"), name ?: uri.lastPathSegment.orEmpty()) }
        return when (copied) {
            is ShareCopy.Copied -> mapOf(
                "path" to copied.file.path,
                "name" to copied.file.name,
                "size" to copied.size,
                "type" to (type ?: try { resolver.getType(uri) } catch (e: Exception) { null }),
            )
            is ShareCopy.Failed -> refused(copied.problem)
        }
    }

    private fun refused(problem: ShareProblem): Map<String, Any?> = mapOf("error" to problem.code)
}
