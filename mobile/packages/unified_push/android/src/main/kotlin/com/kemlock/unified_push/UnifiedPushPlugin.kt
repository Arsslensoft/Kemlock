package com.kemlock.unified_push

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.unifiedpush.android.connector.UnifiedPush

/**
 * UnifiedPush on Android (plan add-unifiedpush): lists the distributors installed, registers this app with the
 * one the person uses, and gives Dart the endpoint it got and the events the service heard
 * ([KemlockPushService]). The connector keeps the choice of distributor; this plugin keeps only the endpoint.
 *
 * The person picks a distributor on the system's own screen (the connector's link activity), which needs a
 * screen to show on, so `start` and `change` need the activity; the rest do not. No call here makes a
 * request of its own: the distributor does the network work.
 */
class UnifiedPushPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var activity: Activity? = null
    private var endpoints: EndpointStore? = null
    private val main = Handler(Looper.getMainLooper())

    // A choice is on the screen: another would put a second one over it
    private var choosing = false

    // Whether this run has registered with the distributor already
    private var registered = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        endpoints = EndpointStore(PreferencesMemory(binding.applicationContext))
        val made = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
        channel = made
        PushEvents.sink = { name, argument -> made.invokeMethod(name, argument) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        PushEvents.sink = null
        channel?.setMethodCallHandler(null)
        channel = null
        endpoints = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val app = context ?: return result.error(NO_CONTEXT, null, null)
        when (call.method) {
            "distributors" -> result.success(distributors(app))
            "endpoint" -> result.success(endpoint(app))
            "start" -> choose(app, result, change = false)
            "change" -> choose(app, result, change = true)
            "stop" -> {
                stop(app)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** The distributors installed with the names the phone shows, and the one in use, which is the connector's saved choice. */
    private fun distributors(app: Context): Map<String, Any?> {
        val installed = UnifiedPush.getDistributors(app).map { mapOf("id" to it, "name" to label(app, it)) }
        // Asking for the saved one also ends the registration of a distributor that was uninstalled
        return mapOf("installed" to installed, "inUse" to UnifiedPush.getSavedDistributor(app))
    }

    private fun label(app: Context, packageName: String): String = try {
        app.packageManager.getApplicationLabel(app.packageManager.getApplicationInfo(packageName, 0)).toString()
    } catch (e: PackageManager.NameNotFoundException) {
        packageName
    }

    /**
     * The endpoint this phone has, or null. With no distributor saved (it was uninstalled and its end of the registration
     * never heard) the kept endpoint is dead: it is forgotten, and Dart hears `unregistered` so the server drops it. A phone
     * that has a distributor but no endpoint yet registers again (the first call of a run registers too, to make sure the
     * distributor is still there), which needs no screen.
     */
    private fun endpoint(app: Context): String? {
        val saved = UnifiedPush.getSavedDistributor(app)
        val kept = endpoints?.getFor(saved) {
            registered = false
            PushEvents.emit("unregistered")
        }
        if ((kept == null || !registered) && saved != null) register(app)
        return kept
    }

    private fun register(app: Context) {
        registered = true
        UnifiedPush.register(app, messageForDistributor = app.applicationInfo.loadLabel(app.packageManager).toString())
    }

    /**
     * Uses the distributor the person already has, or the system's default (the connector asks the person on
     * its own screen when there are several and none is the default), then registers with it. With [change] the
     * person picks again. Answers whether a distributor is in use now: false when none is installed or the person
     * went back.
     */
    private fun choose(app: Context, result: MethodChannel.Result, change: Boolean) {
        val screen = activity ?: return result.error(NO_ACTIVITY, null, null)
        if (choosing) return result.error(BUSY, null, null)
        if (!change && UnifiedPush.getSavedDistributor(app) != null) {
            register(app)
            return result.success(true)
        }
        choosing = true
        val done: (Boolean) -> Unit = { ok ->
            main.post {
                choosing = false
                if (ok) {
                    // The endpoint of the old distributor is not this one's
                    endpoints?.clear()
                    register(app)
                }
                result.success(ok)
            }
        }
        if (change) UnifiedPush.tryPickDistributor(screen, done) else UnifiedPush.tryUseDefaultDistributor(screen, done)
    }

    /** Ends the registration and forgets the endpoint; the server is told by Dart (`DELETE /kem/v1/devices/push-token`). */
    private fun stop(app: Context) {
        endpoints?.clear()
        registered = false
        UnifiedPush.unregister(app)
    }

    private companion object {
        const val CHANNEL = "com.kemlock.app/unified_push"
        const val NO_CONTEXT = "noContext"
        const val NO_ACTIVITY = "noActivity"
        const val BUSY = "busy"
    }
}
