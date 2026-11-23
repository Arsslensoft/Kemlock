package com.kemlock.app.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The app's side of `com.kemlock.app/clipboard` (lib/platform/secret_clipboard.dart): codes and
 * secrets go on the clipboard as a clip labelled [SecretClip.LABEL] that carries the sensitive
 * mark, so Android 13 and later show no preview of it and keyboards don't suggest it. Android
 * has no expiry for a clip, so the app's timer calls `clearIfOurs`. The channel is the process's
 * (`KemlockEngine`), on the application's [context], since that timer runs on after the main
 * screen is closed, as long as the engine does.
 */
class ClipboardChannel(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "com.kemlock.app/clipboard")

    init {
        channel.setMethodCallHandler(this)
    }

    private val clipboard get() = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "copy" -> {
                    val text = call.argument<String>("text") ?: return result.error("failed", "Nothing to copy", null)
                    result.success(copy(text))
                }
                "clearIfOurs" -> {
                    clearIfOurs(call.argument<String>("token").orEmpty())
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("failed", e.message, null)
        }
    }

    private fun copy(text: String): String {
        val clip = ClipData.newPlainText(SecretClip.LABEL, text)
        clip.description.extras = PersistableBundle().apply { putBoolean(SecretClip.sensitiveExtra(Build.VERSION.SDK_INT), true) }
        val manager = clipboard
        manager.setPrimaryClip(clip)
        val timestamp = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) manager.primaryClipDescription?.timestamp else null
        return SecretClip.token(Build.VERSION.SDK_INT, timestamp)
    }

    private fun clearIfOurs(token: String) {
        val manager = clipboard
        // Null in the background from Android 10: Android won't say what is there
        val description = manager.primaryClipDescription
        val timestamp = if (description != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) description.timestamp else null
        if (!SecretClip.shouldClear(token, readable = description != null, timestamp = timestamp)) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) manager.clearPrimaryClip() else manager.setPrimaryClip(ClipData.newPlainText("", ""))
    }
}
