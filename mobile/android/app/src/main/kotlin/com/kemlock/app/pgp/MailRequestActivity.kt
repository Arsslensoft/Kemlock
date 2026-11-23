package com.kemlock.app.pgp

import android.content.Intent
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
import java.lang.ref.WeakReference

/**
 * A mail app's request screen (openspec: add-pgp-mail-provider, decision 3): what the
 * PendingIntent of [KemlockPgpService] opens, in the mail app's task, when it starts it for a
 * result. It is a `FlutterFragmentActivity` on the process's engine, so it shows the open vault's
 * Dart, with `FLAG_SECURE`, out of the recent apps, and not exported. It carries only a request
 * id: the caller and the request are the service's, in memory, and an id the service does not
 * hold is refused. On attaching it tells Dart which request is in front; Dart closes it with
 * `RESULT_OK` and the original request Intent, which the mail app sends again, or
 * `RESULT_CANCELED`.
 */
class MailRequestActivity : FlutterFragmentActivity() {
    private val shared = SharedEngineActivity(this)
    private var requestId: String? = null
    private var closedByDart = false

    override fun onCreate(savedInstanceState: Bundle?) {
        KemlockEngine.obtain(this)
        super.onCreate(savedInstanceState)
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        ObscuredTouches.refuse(this)
        val id = intent.getStringExtra(PgpRequest.EXTRA_REQUEST)
        if (id == null || KemlockPgpService.pending.peek(id) == null) {
            // Forged, or forgotten after ten minutes or a restart of the process
            closedByDart = true
            setResult(RESULT_CANCELED)
            finish()
            return
        }
        requestId = id
        open[id] = WeakReference(this)
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
        val id = requestId ?: return
        val pending = KemlockPgpService.pending.peek(id) ?: return close(false)
        KemlockEngine.channels(this).mail.front(id, pending.caller.toMap())
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (requestId != null) KemlockEngine.channels(this).mail.front(null, null)
        shared.released(flutterEngine)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onStart() {
        super.onStart()
        shared.onStart()
    }

    override fun onDestroy() {
        val id = requestId
        if (isFinishing && id != null) {
            if (open[id]?.get() === this) open.remove(id)
            // Back, or the mail app's task went away: cancelled
            if (!closedByDart) {
                KemlockPgpService.pending.take(id)
                KemlockEngine.channels(this).mail.left(id)
            }
        }
        super.onDestroy()
    }

    /** Ends the screen: with [ok], the request is handed back, with [extras] added, to be sent again. */
    private fun close(ok: Boolean, extras: Map<String, Any?> = emptyMap()) {
        closedByDart = true
        val id = requestId
        val pending = id?.let { KemlockPgpService.pending.take(it) }
        if (ok && pending != null) {
            val back = Intent(pending.request).putExtra(PgpRequest.EXTRA_REQUEST, id)
            PgpRequest.handBack(extras).forEach { PgpIntents.put(back, it) }
            setResult(RESULT_OK, back)
        } else {
            setResult(RESULT_CANCELED)
        }
        finish()
    }

    companion object {
        /** The screen open for each request id. Main thread only. */
        private val open = HashMap<String, WeakReference<MailRequestActivity>>()

        /** Dart closes the screen of [requestId] (lib/features/mail/mail_service.dart). */
        fun finishRequest(requestId: String?, ok: Boolean, extras: Map<String, Any?>) {
            if (requestId == null) return
            val screen = open[requestId]?.get()
            if (screen != null && !screen.isFinishing) screen.close(ok, extras) else KemlockPgpService.pending.take(requestId)
        }
    }
}
