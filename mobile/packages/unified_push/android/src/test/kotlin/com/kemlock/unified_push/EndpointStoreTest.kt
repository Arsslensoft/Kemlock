package com.kemlock.unified_push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The endpoint the service learns of is kept for Dart, and forgotten when the registration ends. */
class EndpointStoreTest {
    private class MapMemory : Memory {
        val values = mutableMapOf<String, String>()

        override fun get(key: String): String? = values[key]

        override fun put(key: String, value: String?) {
            if (value == null) values.remove(key) else values[key] = value
        }
    }

    private val memory = MapMemory()
    private val store = EndpointStore(memory)

    @Test
    fun hasNoEndpointBeforeOneIsGiven() {
        assertNull(store.get())
    }

    @Test
    fun keepsTheEndpointTheDistributorGave() {
        store.set("https://ntfy.example/up123")

        assertEquals("https://ntfy.example/up123", store.get())
    }

    @Test
    fun aNewEndpointReplacesTheOldOne() {
        store.set("https://ntfy.example/old")
        store.set("https://ntfy.example/new")

        assertEquals("https://ntfy.example/new", store.get())
        assertEquals(1, memory.values.size)
    }

    @Test
    fun forgetsTheEndpointWhenTheRegistrationEnds() {
        store.set("https://ntfy.example/up123")

        store.clear()

        assertNull(store.get())
        assertEquals(0, memory.values.size)
    }

    @Test
    fun aBlankEndpointIsNoEndpoint() {
        store.set("https://ntfy.example/up123")

        store.set("  ")

        assertNull(store.get())
    }

    @Test
    fun readsABlankStoredValueAsNone() {
        memory.put("endpoint", "")

        assertNull(store.get())
    }
}
