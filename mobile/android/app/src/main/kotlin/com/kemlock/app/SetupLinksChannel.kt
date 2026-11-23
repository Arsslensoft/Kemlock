package com.kemlock.app

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Hands `otpauth://` and `otpauth-migration://` links to lib/platform/setup_links.dart: the one
 * the app was opened with, asked for once, and those that arrive while it runs. Flutter's own
 * deep linking is off in the manifest, since it would hand the router only the link's path.
 *
 * It belongs to the process's engine (`KemlockEngine`), not to an activity: the engine may have
 * started without one, for a mail app, and Dart asks for the first link only once. So a link a
 * new activity was opened with is the answer to that question while Dart has not asked yet, and
 * arrives like any other once it has.
 */
class SetupLinksChannel(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.kemlock.app/links")
    private var initial: String? = null
    private var asked = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "initial") {
                asked = true
                result.success(initial)
                initial = null
            } else {
                result.notImplemented()
            }
        }
    }

    /** The link an activity was opened with. */
    fun opened(link: String) {
        if (!isSetupLink(link)) return
        if (asked) arrived(link) else initial = link
    }

    fun arrived(link: String) {
        if (isSetupLink(link)) channel.invokeMethod("link", link)
    }

    private fun isSetupLink(link: String) = link.startsWith("otpauth://", ignoreCase = true) || link.startsWith("otpauth-migration://", ignoreCase = true)
}
