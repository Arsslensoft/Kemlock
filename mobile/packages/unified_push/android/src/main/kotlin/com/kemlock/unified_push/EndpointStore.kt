package com.kemlock.unified_push

import android.content.Context

/** Where the endpoint is kept between runs: plain strings by key. */
interface Memory {
    fun get(key: String): String?

    /** Keeps [value], or forgets the key when it is null. */
    fun put(key: String, value: String?)
}

/** [Memory] in the app's private preferences, which no backup rule takes (data_extraction_rules.xml lists the vault's file alone). */
class PreferencesMemory(context: Context) : Memory {
    private val preferences = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    override fun get(key: String): String? = preferences.getString(key, null)

    override fun put(key: String, value: String?) {
        preferences.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    }

    private companion object {
        const val FILE = "kemlock_unified_push"
    }
}

/**
 * The endpoint the distributor gave this app: the URL a server pushes to. It is the one thing the connector
 * does not keep, and the service learns of a new one when the app may not be running, so it is kept here, for
 * the next time Dart asks. It is a capability: anyone who holds it can wake this phone, so it goes nowhere but
 * to the account's server, and it is forgotten when the registration ends.
 */
class EndpointStore(private val memory: Memory) {
    /** The endpoint now, or null when there is none. */
    fun get(): String? = memory.get(KEY)?.takeIf { it.isNotBlank() }

    /** Keeps [url]; a blank one is no endpoint and clears it. */
    fun set(url: String) {
        if (url.isBlank()) clear() else memory.put(KEY, url)
    }

    fun clear() = memory.put(KEY, null)

    /**
     * The endpoint, if a distributor ([saved], the connector's own record) is still there to push to it. Without one the
     * registration is gone, as when the distributor was uninstalled and no `UNREGISTERED` reached the app: the endpoint
     * is forgotten, and [onLost] is told when there was one, so the server drops it rather than get it again each sync.
     */
    fun getFor(saved: String?, onLost: () -> Unit): String? {
        val kept = get()
        if (saved != null) return kept
        if (kept != null) {
            clear()
            onLost()
        }
        return null
    }

    private companion object {
        const val KEY = "endpoint"
    }
}
