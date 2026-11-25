package com.kemlock.unified_push

import android.os.Handler
import android.os.Looper

/**
 * Tells Dart what the service heard, while Dart runs. [sink] is set by the plugin when the Flutter engine
 * attaches and cleared when it goes; while it is null (the process was started for this message alone) an
 * event is dropped: a closed app has no open vault to sync, so a message then changes nothing, and the next
 * open syncs anyway, as on iOS. The endpoint's changes are not lost that way: [EndpointStore] holds them.
 */
object PushEvents {
    /** Told of each event on the main thread, with its name (`endpoint`, `unregistered`, `failed`, `message`) and its argument. */
    @Volatile
    var sink: ((String, Any?) -> Unit)? = null

    private val main = Handler(Looper.getMainLooper())

    /** Sends [name] to Dart from any thread. */
    fun emit(name: String, argument: Any? = null) {
        main.post { sink?.invoke(name, argument) }
    }
}
