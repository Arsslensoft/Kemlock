package com.kemlock.app.clipboard

import android.content.ClipDescription
import android.os.Build

/** How Kemlock marks, names and clears its copies, in plain functions the JVM tests hold. */
object SecretClip {
    /** The clip's label, which some keyboards and clipboard managers show. */
    const val LABEL = "Kemlock"

    /** The name the sensitive mark had before Android 13 made it [ClipDescription.EXTRA_IS_SENSITIVE]. */
    const val OLD_SENSITIVE_EXTRA = "android.content.extra.IS_SENSITIVE"

    /**
     * The extra that marks a clip sensitive on [sdk]: the constant from Android 13, which hides the
     * copy confirmation's preview, and the same string before, which keyboards may honour.
     */
    fun sensitiveExtra(sdk: Int): String = if (sdk >= Build.VERSION_CODES.TIRAMISU) ClipDescription.EXTRA_IS_SENSITIVE else OLD_SENSITIVE_EXTRA

    /**
     * The token naming a copy: the timestamp its description got when it became the primary clip,
     * from Android 8. Before, or when the description can't be read, there is none, and the
     * clear is blind.
     */
    fun token(sdk: Int, timestamp: Long?): String = if (sdk >= Build.VERSION_CODES.O && timestamp != null) timestamp.toString() else ""

    /**
     * Whether `clearIfOurs` clears the clipboard. It leaves a clip it can read and that isn't the
     * copy [token] names; it clears Kemlock's own copy, and blindly, as before, when Android won't
     * say what is there ([readable] false, as in the background from Android 10), or there is no token.
     */
    fun shouldClear(token: String, readable: Boolean, timestamp: Long?): Boolean =
        !readable || token.isEmpty() || timestamp?.toString() == token
}
