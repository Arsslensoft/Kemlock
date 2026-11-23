package com.kemlock.app.engine

import android.content.Context
import android.os.Looper
import com.kemlock.app.SetupLinksChannel
import com.kemlock.app.ShareChannel
import com.kemlock.app.clipboard.ClipboardChannel
import com.kemlock.app.pgp.MailChannel
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * The process's one Flutter engine (openspec: add-pgp-mail-provider, decision 1). It is made on
 * first need, by `MainActivity` or by the mail provider's service, kept in Flutter's engine cache
 * under [ID], and never destroyed: the activities attach to it in turn, and the open vault lives
 * as long as the process and the lock rules allow, not as long as one activity.
 *
 * The channels that belong to the process rather than to a screen are made here, with the
 * engine, before Dart runs, so that a call from Dart always finds them, whichever activity is
 * attached, or none. The channels that need an activity are registered by each activity as it
 * attaches ([SharedEngineActivity]).
 */
object KemlockEngine {
    const val ID = "kemlock"

    private var channels: Channels? = null

    /** What the process's channels are, once the engine is made; [context] is the application's. */
    class Channels(engine: FlutterEngine, context: Context) {
        val links = SetupLinksChannel(engine.dartExecutor.binaryMessenger)

        /** What other apps share (add-share-extension). */
        val share = ShareChannel(context, engine.dartExecutor.binaryMessenger)

        /** The mail provider's (add-pgp-mail-provider). */
        val mail = MailChannel(engine.dartExecutor.binaryMessenger)

        /**
         * Copies of codes and secrets, and their clearing: the app's timer outlives the main screen
         * with the engine, so the channel it clears through must too.
         */
        val clipboard = ClipboardChannel(context, engine.dartExecutor.binaryMessenger)
        private val lifecycle = MethodChannel(engine.dartExecutor.binaryMessenger, "com.kemlock.app/lifecycle")

        /**
         * The main screen was closed for good, which used to end the engine and so lock the vault: Dart
         * locks now, unless a hold is in place (lib/app/app_closed_lock.dart, decision 2).
         */
        fun closed() = lifecycle.invokeMethod("closed", null)
    }

    /** The engine, made and started with Dart's `main` when there is none yet. Main thread only. */
    fun obtain(context: Context): FlutterEngine {
        check(Looper.myLooper() == Looper.getMainLooper()) { "The Flutter engine is made on the main thread" }
        FlutterEngineCache.getInstance().get(ID)?.let { return it }
        // Registers the plugins itself; an activity on a cached engine doesn't register them again
        val engine = FlutterEngine(context.applicationContext)
        channels = Channels(engine, context.applicationContext)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ID, engine)
        return engine
    }

    /** The process's channels, the engine made first if need be. Main thread only. */
    fun channels(context: Context): Channels {
        obtain(context)
        return channels!!
    }
}
