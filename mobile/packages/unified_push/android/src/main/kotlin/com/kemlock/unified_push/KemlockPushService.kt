package com.kemlock.unified_push

import org.unifiedpush.android.connector.FailedReason
import org.unifiedpush.android.connector.PushService
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage

/**
 * What the person's distributor tells this app, through the connector. The server sends an empty Web Push
 * body, so a message's content is never read: any message means "sync now". Nothing here shows a
 * notification, and nothing is logged.
 */
class KemlockPushService : PushService() {
    private val endpoints by lazy { EndpointStore(PreferencesMemory(this)) }

    override fun onNewEndpoint(endpoint: PushEndpoint, instance: String) {
        endpoints.set(endpoint.url)
        PushEvents.emit("endpoint")
    }

    override fun onMessage(message: PushMessage, instance: String) {
        PushEvents.emit("message")
    }

    override fun onRegistrationFailed(reason: FailedReason, instance: String) {
        PushEvents.emit("failed", reason.name)
    }

    override fun onUnregistered(instance: String) {
        endpoints.clear()
        PushEvents.emit("unregistered")
    }
}
