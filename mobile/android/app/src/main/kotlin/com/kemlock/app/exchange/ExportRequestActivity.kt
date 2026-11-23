package com.kemlock.app.exchange

import android.os.Bundle
import android.view.WindowManager
import com.kemlock.app.ObscuredTouches
import com.kemlock.app.autofill.AutofillChannel
import com.kemlock.app.engine.KemlockEngine
import com.kemlock.app.engine.SharedEngineActivity
import com.kemlock.app.securitykey.SecurityKeyChannel
import com.kemlock.app.unlock.UnlockKeyChannel
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * The screen of an export to another app (openspec: plan add-credential-exchange, task 8.4): what
 * the store build's exported activity (`credential_transfer`'s `ExportActivity`) starts for a result
 * once it has checked that the system's selector started it for an entry Kemlock registered. It is
 * a `FlutterFragmentActivity` on the process's engine, like `MailRequestActivity`, so the person
 * sees the open vault's Dart: the lock screen first, then the sheet that says what would go and to
 * which app and asks the owner. `FLAG_SECURE`, out of the recent apps, and not exported.
 *
 * It holds no request and carries no data. The request is the exported activity's, in memory, and
 * Dart answers it through the plugin's channel, which ends both activities; this one ending on its
 * own (Back, the importer's task going away) is a cancel, which `ExportActivity` turns into the
 * importer's cancel. In a build without the plugin, nothing starts it. Switched off with the export
 * itself until the security review of task 8.6 passes: the activity that starts it is.
 */
class ExportRequestActivity : FlutterFragmentActivity() {
    private val shared = SharedEngineActivity(this)

    override fun onCreate(savedInstanceState: Bundle?) {
        KemlockEngine.obtain(this)
        super.onCreate(savedInstanceState)
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        ObscuredTouches.refuse(this)
    }

    override fun getCachedEngineId(): String = KemlockEngine.ID

    // Never read from the intent's extras, as Flutter does: the engine is the process's (MainActivity)
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.opaque

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        // The lock screen's biometric unlock and the rest need this activity while it has the engine
        AutofillChannel(this, messenger)
        UnlockKeyChannel(this, messenger)
        SecurityKeyChannel(this, messenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        shared.released(flutterEngine)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onStart() {
        super.onStart()
        shared.onStart()
    }
}
