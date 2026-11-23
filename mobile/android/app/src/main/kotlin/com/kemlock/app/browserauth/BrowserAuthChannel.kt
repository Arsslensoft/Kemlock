package com.kemlock.app.browserauth

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.URI
import java.net.URISyntaxException
import java.net.URLDecoder
import java.security.MessageDigest

/**
 * What the SSO redirect to `kemlock://sso` has to be to count: this sign-in's own. Another app can claim the
 * `kemlock` scheme, and any app can start the activity with an intent, so a redirect is taken only when its `state`
 * is the one Dart made for the sign-in in progress. The code it carries is useless without Dart's PKCE verifier and
 * the device key either way. No Android here, so a unit test runs it.
 */
object SsoCallback {
    const val SCHEME = "kemlock"
    const val HOST = "sso"

    /** A state of 16 to 256 URL-safe characters, as the server takes it. */
    fun isValidState(state: String): Boolean = state.length in 16..256 && state.all { it.isLetterOrDigit() || it == '-' || it == '_' }

    /** [link] when it is a redirect to `kemlock://sso` carrying [state], else null. */
    fun accept(link: String, state: String): String? {
        val uri = try {
            URI(link)
        } catch (e: URISyntaxException) {
            return null
        }
        if (!SCHEME.equals(uri.scheme, ignoreCase = true) || !HOST.equals(uri.host, ignoreCase = true)) return null
        val got = query(uri.rawQuery)["state"] ?: return null
        return if (MessageDigest.isEqual(got.toByteArray(Charsets.UTF_8), state.toByteArray(Charsets.UTF_8))) link else null
    }

    /** The query's parameters, URL-decoded; the first of a repeated name wins. */
    fun query(raw: String?): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        if (raw.isNullOrEmpty()) return out
        for (pair in raw.split('&')) {
            val at = pair.indexOf('=')
            val name = URLDecoder.decode(if (at < 0) pair else pair.substring(0, at), "UTF-8")
            val value = if (at < 0) "" else URLDecoder.decode(pair.substring(at + 1), "UTF-8")
            out.putIfAbsent(name, value)
        }
        return out
    }
}

/**
 * Opens the provider's page in the system's browser, as a Custom Tab where the browser has them, and hands the
 * redirect back to `lib/platform/browser_auth.dart`. The tab is the browser's own: the app draws no view of its own
 * and never sees the page.
 *
 * Custom Tabs are asked for with the raw intent extra (`android.support.customtabs.extra.SESSION`, an empty
 * session), which a browser that supports them reads and any other ignores, so the screen needs no
 * `androidx.browser` dependency. A tab closed with Back sends nothing back, so Dart ends the wait itself, from the
 * sign-in sheet's Cancel.
 *
 * The redirect arrives at `MainActivity.onNewIntent` through its `kemlock://sso` filter, which calls [arrived].
 */
class BrowserAuthChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.kemlock.app/browser_auth")
    private var pending: MethodChannel.Result? = null
    private var state: String? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "authenticate" -> start(call, result)
                "cancel" -> {
                    end()?.error("cancelled", null, null)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        val state = call.argument<String>("state")
        if (url == null || state == null || !SsoCallback.isValidState(state)) {
            result.error("failed", "A sign-in needs an address and a state.", null)
            return
        }
        val uri = Uri.parse(url)
        // The person's credentials go to this page: never plain http
        if (uri.scheme != "https" || uri.host.isNullOrEmpty()) {
            result.error("failed", "The provider's address isn't https.", null)
            return
        }
        // A second sign-in replaces the first, which ends as a cancel
        end()?.error("cancelled", null, null)
        pending = result
        this.state = state
        val intent = Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE)
        val extras = Bundle()
        extras.putBinder(CUSTOM_TABS_SESSION, null)
        intent.putExtras(extras)
        try {
            activity.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            end()?.error("failed", "No browser is installed.", null)
        }
    }

    /** A link the activity was started with. Returns whether it was the pending sign-in's redirect. */
    fun arrived(link: String): Boolean {
        val expected = state ?: return false
        val accepted = SsoCallback.accept(link, expected) ?: return false
        end()?.success(accepted)
        return true
    }

    private fun end(): MethodChannel.Result? {
        val result = pending
        pending = null
        state = null
        return result
    }

    private companion object {
        const val CUSTOM_TABS_SESSION = "android.support.customtabs.extra.SESSION"
    }
}
