package com.kemlock.app

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import com.kemlock.app.autofill.AutofillChannel
import com.kemlock.app.browserauth.BrowserAuthChannel
import com.kemlock.app.devicekeys.DeviceKeyChannel
import com.kemlock.app.engine.KemlockEngine
import com.kemlock.app.engine.SharedEngineActivity
import com.kemlock.app.platformpasskey.PlatformPasskeyChannel
import com.kemlock.app.securitykey.SecurityKeyChannel
import com.kemlock.app.unlock.UnlockKeyChannel
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// A FlutterFragmentActivity, which local_auth and biometric unlock's channel need to show the biometric prompt.
class MainActivity : FlutterFragmentActivity() {
    private val shared = SharedEngineActivity(this)
    private var browserAuth: BrowserAuthChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // The process's one engine, which the mail provider's service shares (KemlockEngine)
        val channels = KemlockEngine.channels(this)
        super.onCreate(savedInstanceState)
        // Keeps codes and secrets out of screenshots, screen recordings and the recent-apps preview,
        // as the Capacitor app's MainActivity did.
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        ObscuredTouches.refuse(this)
        // A recreated activity's link and share were handed over when it was first made
        if (savedInstanceState == null) {
            val started = intent
            // The intent that made Kemlock's task comes again when it is opened from the recent apps:
            // its link was handed over then, as its share was
            if (started != null && !ShareIntent.reopened(started.flags)) started.data?.let { channels.links.opened(it.toString()) }
            channels.share.opened(started)
        }
    }

    override fun getCachedEngineId(): String = KemlockEngine.ID

    // Flutter reads both of these from the intent's extras, which any app that starts this screen
    // writes. The engine is the process's, and the open vault with it: no intent ends it.
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.opaque

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AutofillChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        UnlockKeyChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        DeviceKeyChannel(flutterEngine.dartExecutor.binaryMessenger)
        browserAuth = BrowserAuthChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        PlatformPasskeyChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        SecurityKeyChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        shared.released(flutterEngine)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onStart() {
        super.onStart()
        shared.onStart()
    }

    override fun onDestroy() {
        // Closed for good, with Back or from the recent apps: the engine stays, so Dart is told
        if (isFinishing) KemlockEngine.channels(this).closed()
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val channels = KemlockEngine.channels(this)
        intent.data?.let { channels.links.arrived(it.toString()) }
        // The SSO redirect goes to the sign-in that waits for it, and only one carrying its state
        intent.data?.let { browserAuth?.arrived(it.toString()) }
        channels.share.arrived(intent)
    }
}
