package com.kemlock.app.pgp

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch

/**
 * The native side of `com.kemlock.app/mail` (lib/platform/mail_requests.dart): the mail
 * provider's service hands Dart each request and gets its answer, and the request screen says
 * which request is in front and is closed by Dart. It belongs to the process's engine
 * (`KemlockEngine`), so Dart answers with no activity attached. Main thread only, but for
 * [ready], which the service's binder threads wait on.
 */
class MailChannel(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.kemlock.app/mail")

    /** Counted down once Dart serves the channel. */
    val ready = CountDownLatch(1)

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    ready.countDown()
                    result.success(null)
                }
                "finish" -> {
                    val extras = call.argument<Map<String, Any?>>("extras").orEmpty()
                    MailRequestActivity.finishRequest(call.argument<String>("requestId"), call.argument<Boolean>("ok") == true, extras)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Hands a request to Dart; [answered] gets Dart's answer, or null when there was none. */
    fun execute(args: Map<String, Any?>, answered: (Map<*, *>?) -> Unit) {
        channel.invokeMethod(
            "execute",
            args,
            object : MethodChannel.Result {
                override fun success(result: Any?) = answered(result as? Map<*, *>)

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) = answered(null)

                override fun notImplemented() = answered(null)
            },
        )
    }

    /** The request screen of [requestId], for [caller], is in front; null when it no longer is. */
    fun front(requestId: String?, caller: Map<String, Any?>?) = channel.invokeMethod("front", mapOf("requestId" to requestId, "caller" to caller))

    /** The request screen of [requestId] went away without Dart closing it. */
    fun left(requestId: String) = channel.invokeMethod("left", mapOf("requestId" to requestId))
}
