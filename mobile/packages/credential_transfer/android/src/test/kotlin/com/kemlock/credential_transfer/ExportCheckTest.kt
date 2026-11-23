package com.kemlock.credential_transfer

import android.content.pm.ApplicationInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A [NonceStore] in memory, as the preferences would hold it. */
class MemoryNonceStore : NonceStore {
    var entries: Map<String, String> = emptyMap()

    override fun read(): Map<String, String> = entries

    override fun write(entries: Map<String, String>) {
        this.entries = entries
    }
}

/** The two checks the exported activity makes before any Dart is called (task 8.4). */
class ExportCheckTest {
    private val store = MemoryNonceStore()
    private val nonces = ExportNonces(store)

    /** Every package is a system app, unless a test says otherwise. */
    private val system: (String) -> Boolean = { true }

    private fun registered(vararg vaults: String): Map<String, String> = nonces.issue(vaults.toList()).also { nonces.commit(it) }

    @Test
    fun allowsTheSelectorWithAnIdKemlockRegistered() {
        val ids = registered("main", "work")

        val verdict = ExportCheck.verdict("com.google.android.gms", ids.getValue("work"), nonces, system)

        assertEquals(ExportVerdict.Allowed("work"), verdict)
    }

    @Test
    fun refusesAnyOtherCallerWhateverTheId() {
        val ids = registered("main")

        for (caller in listOf("com.evil.app", "com.google.android.gms.fake", "com.kemlock.app", "")) {
            assertEquals(caller, ExportVerdict.Refused(ExportRefusal.UNTRUSTED_CALLER), ExportCheck.verdict(caller, ids.getValue("main"), nonces, system))
        }
    }

    @Test
    fun refusesAStartWithNoCallingPackage() {
        // Started with startActivity and not for a result, as any app can
        val ids = registered("main")

        assertEquals(ExportVerdict.Refused(ExportRefusal.UNTRUSTED_CALLER), ExportCheck.verdict(null, ids.getValue("main"), nonces, system))
    }

    @Test
    fun refusesAWrongOrMissingIdFromTheSelector() {
        registered("main")

        for (id in listOf("guess", "", null, "0".repeat(64))) {
            assertEquals("$id", ExportVerdict.Refused(ExportRefusal.UNKNOWN_ENTRY), ExportCheck.verdict("com.google.android.gms", id, nonces, system))
        }
    }

    @Test
    fun refusesWhenNothingWasRegistered() {
        assertEquals(ExportVerdict.Refused(ExportRefusal.UNKNOWN_ENTRY), ExportCheck.verdict("com.google.android.gms", "anything", nonces, system))
    }

    @Test
    fun checksTheCallerBeforeTheId() {
        // A wrong caller is told apart from a wrong id: the id is never looked up for it
        val reading = object : NonceStore {
            var reads = 0

            override fun read(): Map<String, String> {
                reads++
                return emptyMap()
            }

            override fun write(entries: Map<String, String>) {}
        }

        ExportCheck.verdict("com.evil.app", "id", ExportNonces(reading), system)

        assertEquals(0, reading.reads)
    }

    @Test
    fun anIdFromBeforeTheLastRegistrationNoLongerWorks() {
        val old = registered("main")
        val current = registered("main")

        assertNotEquals(old.getValue("main"), current.getValue("main"))
        assertEquals(ExportVerdict.Refused(ExportRefusal.UNKNOWN_ENTRY), ExportCheck.verdict("com.google.android.gms", old.getValue("main"), nonces, system))
        assertEquals(ExportVerdict.Allowed("main"), ExportCheck.verdict("com.google.android.gms", current.getValue("main"), nonces, system))
    }

    @Test
    fun clearingForgetsEveryId() {
        val ids = registered("main")

        nonces.clear()

        assertNull(nonces.vaultOf(ids.getValue("main")))
    }

    @Test
    fun anIdThatWasIssuedButNotCommittedIsNotYetValid() {
        // The system has not got it yet: a failed registration leaves the old ones
        val issued = nonces.issue(listOf("main"))

        assertNull(nonces.vaultOf(issued.getValue("main")))
    }

    @Test
    fun keepsOnlyHashesAndLongRandomIds() {
        val ids = registered("main", "work")
        val id = ids.getValue("main")

        assertEquals(64, id.length)
        assertNotEquals(id, ids.getValue("work"))
        // What is kept can't give an id back
        assertFalse(store.entries.keys.contains(id))
        assertFalse(store.entries.values.contains(id))
        assertTrue(store.entries.keys.all { it.length == 64 && it != id })
        assertEquals(ExportNonces.hash(id), store.entries.entries.first { it.value == "main" }.key)
    }

    @Test
    fun refusesTheSelectorsPackageNameWhenThePackageIsNotASystemApp() {
        // An app installed under the name on a phone without Play services
        val ids = registered("main")

        val verdict = ExportCheck.verdict("com.google.android.gms", ids.getValue("main"), nonces, { false })

        assertEquals(ExportVerdict.Refused(ExportRefusal.UNTRUSTED_CALLER), verdict)
    }

    @Test
    fun refusesAPackageTheLookupCannotVouchFor() {
        val ids = registered("main")
        val lookups = mutableListOf<String>()

        val verdict = ExportCheck.verdict("com.google.android.gms", ids.getValue("main"), nonces, { lookups += it; false })

        assertEquals(ExportVerdict.Refused(ExportRefusal.UNTRUSTED_CALLER), verdict)
        assertEquals(listOf("com.google.android.gms"), lookups)
    }

    @Test
    fun looksUpOnlyAPackageThatHasTheSelectorsName() {
        // Another app's package is refused on its name, with no look-up of it
        val ids = registered("main")
        val lookups = mutableListOf<String>()

        ExportCheck.verdict("com.evil.app", ids.getValue("main"), nonces, { lookups += it; true })

        assertTrue(lookups.isEmpty())
    }

    @Test
    fun aSystemAppIsTrustedWhetherOrNotItWasUpdated() {
        // Play services is a system app with an update installed over it on most phones
        assertTrue(ExportCheck.isSystemApp(ApplicationInfo.FLAG_SYSTEM))
        assertTrue(ExportCheck.isSystemApp(ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP))
        assertTrue(ExportCheck.isSystemApp(ApplicationInfo.FLAG_UPDATED_SYSTEM_APP))
        assertTrue(ExportCheck.isSystemApp(ApplicationInfo.FLAG_HAS_CODE or ApplicationInfo.FLAG_SYSTEM))
    }

    @Test
    fun anAppInstalledByThePersonIsNotASystemApp() {
        assertFalse(ExportCheck.isSystemApp(0))
        assertFalse(ExportCheck.isSystemApp(ApplicationInfo.FLAG_HAS_CODE or ApplicationInfo.FLAG_ALLOW_BACKUP))
    }

    @Test
    fun checksThatTheCallerIsTheSelectorAndASystemAppBeforeTheId() {
        val reading = object : NonceStore {
            var reads = 0

            override fun read(): Map<String, String> {
                reads++
                return emptyMap()
            }

            override fun write(entries: Map<String, String>) {}
        }

        ExportCheck.verdict("com.google.android.gms", "id", ExportNonces(reading), { false })

        assertEquals(0, reading.reads)
    }

    @Test
    fun callerTrustedNeedsTheNameAndTheSystemFlag() {
        assertTrue(ExportCheck.callerTrusted("com.google.android.gms", { true }))
        assertFalse(ExportCheck.callerTrusted("com.google.android.gms", { false }))
        assertFalse(ExportCheck.callerTrusted("com.evil.app", { true }))
        assertFalse(ExportCheck.callerTrusted(null, { true }))
    }

    @Test
    fun allowsAContentUriOfAnotherApp() {
        val own = setOf("com.kemlock.app.fileprovider", "com.kemlock.app.androidx-startup")

        assertTrue(ExportCheck.targetAllowed("content", "com.onepassword.android.fileprovider", own))
        assertTrue(ExportCheck.targetAllowed("CONTENT", "com.x8bit.bitwarden.fileprovider", own))
    }

    @Test
    fun refusesAContentUriOfKemlocksOwnProviders() {
        val own = setOf("com.kemlock.app.fileprovider", "com.kemlock.app.share", "com.kemlock.app.mail")

        for (authority in listOf("com.kemlock.app.fileprovider", "COM.KEMLOCK.APP.FILEPROVIDER", "10@com.kemlock.app.fileprovider", "com.kemlock.app.fileprovider:8080")) {
            assertFalse(authority, ExportCheck.targetAllowed("content", authority, own))
        }
    }

    @Test
    fun refusesEachOfSeveralOwnAuthorities() {
        // The activity splits `android:authorities`, which holds several, into one entry each
        assertFalse(ExportCheck.targetAllowed("content", "com.kemlock.app.mail", setOf("com.kemlock.app.share", "com.kemlock.app.mail")))
    }

    @Test
    fun refusesAUriThatIsNotAContentUriWithAnAuthority() {
        val own = emptySet<String>()

        assertFalse(ExportCheck.targetAllowed(null, "com.example.files", own))
        assertFalse(ExportCheck.targetAllowed("file", "com.example.files", own))
        assertFalse(ExportCheck.targetAllowed("https", "example.com", own))
        assertFalse(ExportCheck.targetAllowed("content", null, own))
        assertFalse(ExportCheck.targetAllowed("content", "", own))
        assertFalse(ExportCheck.targetAllowed("content", "10@", own))
    }

    @Test
    fun anyIsTrueOnlyWhileIdsAreKept() {
        assertFalse(nonces.any())

        val ids = registered("main")
        assertTrue(nonces.any())
        assertNull(nonces.vaultOf(null))
        assertEquals("main", nonces.vaultOf(ids.getValue("main")))

        nonces.clear()
        assertFalse(nonces.any())
    }

    @Test
    fun anIssuedButUncommittedIdIsNotAnEntryTheSystemHolds() {
        nonces.issue(listOf("main"))

        assertFalse(nonces.any())
    }
}
