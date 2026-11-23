package com.kemlock.app.engine

import android.app.Activity
import io.flutter.embedding.engine.FlutterEngine

/**
 * What an activity on [KemlockEngine]'s engine does as the engine comes and goes (openspec:
 * add-pgp-mail-provider, decisions 1 and 3). The engine attaches to one activity at a time:
 * when another attaches, Flutter detaches this one first (its `cleanUpFlutterEngine`, then the
 * other's `configureFlutterEngine`), and this one's Flutter view is gone for good. So:
 *
 * - [released] lets go of the channels that hold this activity, which the next activity
 *   registers again with itself, so that no call from Dart reaches an activity that is not
 *   attached, or is destroyed;
 * - and an activity whose engine was taken while it lived recreates itself when it next comes
 *   to the front ([onStart]), which attaches it again.
 */
class SharedEngineActivity(private val activity: Activity) {
    private var taken = false

    /** The activity's `cleanUpFlutterEngine`: it is leaving the engine, or the engine it. */
    fun released(engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger
        for (name in ACTIVITY_CHANNELS) messenger.setMessageHandler(name, null)
        // Only a living activity can come back: one that is finishing, or turning, is not taken
        if (!activity.isFinishing && !activity.isChangingConfigurations) taken = true
    }

    /** The activity's `onStart`, after `super.onStart()`. */
    fun onStart() {
        if (!taken) return
        taken = false
        activity.recreate()
    }

    companion object {
        /**
         * The channels an activity registers with itself in `configureFlutterEngine`. Never a
         * channel of [KemlockEngine.Channels], such as `com.kemlock.app/clipboard`, which would be
         * gone for good once the activity let go of it.
         */
        val ACTIVITY_CHANNELS = listOf(
            "com.kemlock.app/autofill",
            "com.kemlock.app/unlock",
            "com.kemlock.app/security_keys",
            "com.kemlock.app/security_keys/events",
        )
    }
}
