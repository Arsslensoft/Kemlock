package com.kemlock.app.securitykey

import android.content.pm.PackageManager
import android.nfc.NfcAdapter
import android.os.Handler
import android.os.Looper
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Why the phone could not reach a security key or carry a message to it; [code] is what
 * lib/platform/security_keys.dart reads. Android sends only some of them: the others are
 * iPhone's, and are here so the two sides share one list.
 */
sealed class SecurityKeyError(val code: String, message: String? = null) : Exception(message) {
    /** The app closed the link while a message was on its way. */
    class Cancelled : SecurityKeyError("cancelled")

    /** The phone has no way to reach a key over the link asked for. */
    class Unavailable : SecurityKeyError("unavailable")

    /** The phone has NFC and it is turned off. */
    class NfcOff : SecurityKeyError("nfcOff")

    /** The person refused the system's question about a USB key. */
    class Denied : SecurityKeyError("denied")

    /** The key left the NFC field or was unplugged. */
    class Removed : SecurityKeyError("removed")

    /** The key gave no answer in time. */
    class Timeout : SecurityKeyError("timeout")

    /** The key has no application with the identifier asked for (iPhone). */
    class NoApplication : SecurityKeyError("noApplication")

    /** The application's identifier is not in iPhone's list. */
    class NotDeclared : SecurityKeyError("notDeclared")

    class Failed(message: String?) : SecurityKeyError("failed", message)
}

/** Answers a channel call with [error], as the Dart side reads it. Main thread only, as every answer. */
internal fun MethodChannel.Result.fail(error: SecurityKeyError) = error(error.code, error.message, null)

/**
 * The app's side of `com.kemlock.app/security_keys` and of its event channel
 * (lib/platform/security_keys.dart): it finds security keys held to the phone ([NfcLinks]) or
 * plugged in ([UsbLinks]) and carries bytes to them. It knows nothing of what the bytes mean:
 * APDU chaining, CTAPHID and CCID framing and CBOR are Dart, in lib/security_key/.
 *
 * The search runs only while the event channel is listened to. Nothing about a key is kept,
 * logged or copied: a key is named by a counter (NFC) or by the kernel's number for this
 * plug-in (USB), and both mean nothing once it has left.
 */
class SecurityKeyChannel(private val activity: FragmentActivity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val channel = MethodChannel(messenger, "com.kemlock.app/security_keys")
    private val events = EventChannel(messenger, "com.kemlock.app/security_keys/events")
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private val nfc = NfcLinks(activity, main, ::tell)
    private val usb = UsbLinks(activity, main, ::tell)

    init {
        channel.setMethodCallHandler(this)
        events.setStreamHandler(this)
        // Reader mode belongs to a resumed activity: off when the app is paused, back on when
        // it returns and the stream is still listened to.
        activity.lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onResume(owner: LifecycleOwner) = nfc.resumed(true)

            override fun onPause(owner: LifecycleOwner) = nfc.resumed(false)

            override fun onDestroy(owner: LifecycleOwner) {
                sink = null
                nfc.shutDown()
                usb.shutDown()
            }
        })
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "capabilities" -> result.success(capabilities())
                "present" -> usb.present(result)
                "requestPermission" -> {
                    val device = call.argument<String>("device") ?: return result.fail(SecurityKeyError.Failed("No device"))
                    usb.requestPermission(device, result)
                }
                // iPhone's reader session and the text on its sheet. Android reads for as long as the stream is listened to.
                "beginNfc", "setNfcMessage", "endNfc" -> result.success(null)
                "open" -> {
                    val link = call.argument<String>("link") ?: return result.fail(SecurityKeyError.Failed("No link"))
                    if (NfcLinks.owns(link)) nfc.open(link, result) else usb.open(link, result)
                }
                "close" -> {
                    val link = call.argument<String>("link") ?: return result.success(null)
                    if (NfcLinks.owns(link)) nfc.close(link, result) else usb.close(link, result)
                }
                "transceive" -> {
                    val link = call.argument<String>("link") ?: return result.fail(SecurityKeyError.Failed("No link"))
                    val data = call.argument<ByteArray>("data") ?: return result.fail(SecurityKeyError.Failed("No data"))
                    if (!NfcLinks.owns(link)) return result.fail(SecurityKeyError.Failed("This link carries frames, not APDUs"))
                    nfc.transceive(link, data, timeout(call), result)
                }
                "write" -> {
                    val link = call.argument<String>("link") ?: return result.fail(SecurityKeyError.Failed("No link"))
                    val frames = call.argument<List<Any?>>("frames").orEmpty().filterIsInstance<ByteArray>()
                    if (NfcLinks.owns(link)) return result.fail(SecurityKeyError.Failed("This link carries APDUs, not frames"))
                    usb.write(link, frames, result)
                }
                "read" -> {
                    val link = call.argument<String>("link") ?: return result.fail(SecurityKeyError.Failed("No link"))
                    if (NfcLinks.owns(link)) return result.fail(SecurityKeyError.Failed("This link carries APDUs, not frames"))
                    usb.read(link, timeout(call), result)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.fail(SecurityKeyError.Failed(e.message ?: e.javaClass.simpleName))
        }
    }

    private fun timeout(call: MethodCall): Int = call.argument<Number>("timeoutMs")?.toInt()?.coerceAtLeast(0) ?: 0

    /** What this phone can reach a key with. Never fails: what can't be asked is false. */
    private fun capabilities(): Map<String, Any?> {
        val adapter = runCatching { NfcAdapter.getDefaultAdapter(activity) }.getOrNull()
        return mapOf(
            "nfc" to (adapter != null),
            "nfcOn" to (runCatching { adapter?.isEnabled == true }.getOrDefault(false)),
            "usb" to runCatching { activity.packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST) }.getOrDefault(false),
            "smartcards" to false,
            "readsOnRequest" to false,
        )
    }

    /** Listening starts the search: NFC reader mode and the USB receiver. */
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        nfc.listen(true)
        usb.watch(true)
    }

    /** Cancelling stops it. */
    override fun onCancel(arguments: Any?) {
        sink = null
        nfc.listen(false)
        usb.watch(false)
    }

    /** Sends an `arrived` or `left` event, when someone listens. Main thread only. */
    private fun tell(event: Map<String, Any?>) {
        sink?.success(event)
    }
}
