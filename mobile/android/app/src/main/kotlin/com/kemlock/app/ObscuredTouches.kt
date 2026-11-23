package com.kemlock.app

import android.app.Activity
import android.os.Build

/**
 * Keeps another app's window from taking the person's taps on Kemlock's screens (security audit
 * 2026-11-21, L9): an app allowed to draw over others could lay a screen of its own over the
 * vault, a mail app's approval, a fill or a passkey, and have the person tap through it. From
 * Android 12 the other apps' overlays are hidden while such a screen shows; on every version, a
 * tap Android marks as having come through another window is dropped, which Android 12 and up
 * mostly do themselves.
 */
object ObscuredTouches {
    /** For [activity], once its content is set. */
    fun refuse(activity: Activity) {
        val window = activity.window
        // On the decor view, every view of the window under it: a view group drops such a tap before its children see it
        window.decorView.filterTouchesWhenObscured = true
        // HIDE_OVERLAY_WINDOWS, in the manifest
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) window.setHideOverlayWindows(true)
    }
}
