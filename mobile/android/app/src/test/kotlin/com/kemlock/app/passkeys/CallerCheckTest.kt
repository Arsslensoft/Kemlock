package com.kemlock.app.passkeys

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException

class CallerCheckTest {
    /** The list the app is built with. */
    private val bundled: String = run {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            for (path in listOf("src/main/res/raw/passkey_browsers.json", "app/src/main/res/raw/passkey_browsers.json")) {
                val file = File(dir, path)
                if (file.exists()) return@run file.readText()
            }
            dir = dir.parentFile
        }
        throw IllegalStateException("No res/raw/passkey_browsers.json above ${System.getProperty("user.dir")}")
    }

    private fun digest(fingerprint: String) = fingerprint.split(":").map { it.toInt(16).toByte() }.toByteArray()

    // Chrome's release and userdebug certificates, as the bundled list has them
    private val chromeRelease = digest("F0:FD:6C:5B:41:0F:25:CB:25:C3:B5:33:46:C8:97:2F:AE:30:F8:EE:74:11:DF:91:04:80:AD:6B:2D:60:DB:83")
    private val chromeUserdebug = digest("19:75:B2:F1:71:77:BC:89:A5:DF:F3:1F:9E:64:A6:CA:E2:81:A5:3D:C1:D1:D5:9B:1D:14:7F:E1:C8:2A:FA:00")
    private val appCert = ByteArray(32) { (it * 7).toByte() }
    private val otherCert = ByteArray(32) { (it * 3 + 1).toByte() }

    private fun browser(packageName: String, cert: ByteArray, origin: String? = "https://webauthn.io") =
        Caller(packageName, listOf(cert), listOf(cert), multipleSigners = false, forWebsite = true, origin = origin)

    private fun app(packageName: String = "com.example.shop", certs: List<ByteArray> = listOf(appCert), lineage: List<ByteArray> = certs) =
        Caller(packageName, certs, if (certs.size > 1) emptyList() else lineage, multipleSigners = certs.size > 1, forWebsite = false, origin = null)

    private fun links(packageName: String, vararg prints: ByteArray, relation: String = "delegate_permission/common.get_login_creds") = """
        [{"relation":["delegate_permission/common.handle_all_urls_not"],"target":{"namespace":"web","site":"https://example.com"}},
         {"relation":["$relation"],"target":{"namespace":"android_app","package_name":"$packageName",
          "sha256_cert_fingerprints":[${prints.joinToString(",") { "\"" + fingerprint(it).lowercase() + "\"" }}]}}]
    """.trimIndent()

    private class Site(var json: String? = null, var fails: Boolean = false) : AssetLinksSource {
        val asked = mutableListOf<String>()

        override fun fetch(host: String): String {
            asked += host
            if (fails) throw IOException("No network")
            return json ?: throw IOException("HTTP 404")
        }
    }

    private fun check(caller: Caller, rpId: String, site: Site = Site(), browsers: TrustedBrowsers = TrustedBrowsers(bundled)) =
        CallerCheck(browsers, AssetLinks(site)).check(caller, rpId)

    @Test
    fun theBundledListHasTheBrowsersPeopleUse() {
        val packages = TrustedBrowsers(bundled).packages
        for (name in listOf("com.android.chrome", "org.mozilla.firefox", "com.microsoft.emmx", "com.brave.browser", "com.sec.android.app.sbrowser")) {
            assertTrue(name, name in packages)
        }
    }

    @Test
    fun answersAListedBrowserForTheSiteItNames() {
        val site = Site()
        assertEquals(Verdict.Allowed("https://webauthn.io"), check(browser("com.android.chrome", chromeRelease), "webauthn.io", site))
        assertEquals(Verdict.Allowed("https://login.webauthn.io"), check(browser("com.android.chrome", chromeRelease, "https://login.webauthn.io"), "webauthn.io"))
        assertEquals(Verdict.Allowed("http://localhost:8080"), check(browser("com.android.chrome", chromeRelease, "http://localhost:8080"), "localhost"))
        // A browser's word is checked against the list, never against the site
        assertEquals(emptyList<String>(), site.asked)
    }

    @Test
    fun refusesAListedBrowserForASiteTheRelyingPartyDoesntCover() {
        for (origin in listOf("https://evil.io", "https://webauthn.io.evil.io", "https://notwebauthn.io", "http://webauthn.io", "https://user@webauthn.io", "webauthn.io")) {
            assertEquals(origin, Verdict.Refused(Refusal.WRONG_SITE), check(browser("com.android.chrome", chromeRelease, origin), "webauthn.io"))
        }
    }

    @Test
    fun refusesAnUnlistedBrowser() {
        val unlisted = Verdict.Refused(Refusal.UNTRUSTED_BROWSER)
        assertEquals(unlisted, check(browser("com.example.browser", chromeRelease), "webauthn.io"))
        // Chrome's package name signed by someone else
        assertEquals(unlisted, check(browser("com.android.chrome", otherCert), "webauthn.io"))
        // A userdebug build's certificate counts only on a userdebug phone
        assertEquals(unlisted, check(browser("com.android.chrome", chromeUserdebug), "webauthn.io"))
        assertEquals(
            Verdict.Allowed("https://webauthn.io"),
            check(browser("com.android.chrome", chromeUserdebug), "webauthn.io", browsers = TrustedBrowsers(bundled, includeUserdebug = true)),
        )
        // On the list, but androidx kept the origin back
        assertEquals(unlisted, check(browser("com.android.chrome", chromeRelease, origin = null), "webauthn.io"))
        assertEquals(unlisted, check(browser("com.android.chrome", chromeRelease), "webauthn.io", browsers = TrustedBrowsers("not json")))
    }

    @Test
    fun answersAnAppTheSiteLists() {
        val site = Site(links("com.example.shop", appCert))
        val verdict = check(app(), "Example.com", site)
        assertEquals(Verdict.Allowed("android:apk-key-hash:" + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(appCert)), verdict)
        assertEquals(listOf("example.com"), site.asked)
        // An app whose key was rotated, listed by the certificate it is signed with now
        assertEquals(
            Verdict.Allowed(CallerCheck.appOrigin(app(certs = listOf(otherCert)))),
            check(app(certs = listOf(otherCert), lineage = listOf(appCert, otherCert)), "example.com", Site(links("com.example.shop", otherCert))),
        )
    }

    @Test
    fun refusesAnAppTheSiteListsOnlyForItsLinksOrByARetiredKey() {
        val notListed = Verdict.Refused(Refusal.NOT_LISTED)
        // handle_all_urls hands the app the site's links, not its sign-ins
        assertEquals(notListed, check(app(), "example.com", Site(links("com.example.shop", appCert, relation = "delegate_permission/common.handle_all_urls"))))
        // The site lists only the key the app was rotated away from, not the one it is signed with now
        assertEquals(
            notListed,
            check(app(certs = listOf(otherCert), lineage = listOf(appCert, otherCert)), "example.com", Site(links("com.example.shop", appCert))),
        )
    }

    @Test
    fun refusesAnAppTheSiteDoesntList() {
        val notListed = Verdict.Refused(Refusal.NOT_LISTED)
        // Another app of the site
        assertEquals(notListed, check(app(), "example.com", Site(links("com.example.other", appCert))))
        // The same package name, signed by someone else
        assertEquals(notListed, check(app(), "example.com", Site(links("com.example.shop", otherCert))))
        // Listed for something other than signing in
        assertEquals(notListed, check(app(), "example.com", Site(links("com.example.shop", appCert, relation = "delegate_permission/common.use_as_origin"))))
        // Several signers must all be listed
        assertEquals(notListed, check(app(certs = listOf(appCert, otherCert)), "example.com", Site(links("com.example.shop", appCert))))
        assertEquals(
            Verdict.Allowed(CallerCheck.appOrigin(app(certs = listOf(appCert, otherCert)))),
            check(app(certs = listOf(appCert, otherCert)), "example.com", Site(links("com.example.shop", appCert, otherCert))),
        )
        assertEquals(notListed, check(app(), "example.com", Site("[]")))
    }

    @Test
    fun refusesAnAppWhenTheSitesListCantBeHad() {
        val noLinks = Verdict.Refused(Refusal.NO_ASSET_LINKS)
        assertEquals(noLinks, check(app(), "example.com", Site(fails = true)))
        assertEquals(noLinks, check(app(), "example.com", Site(json = null)))
        assertEquals(noLinks, check(app(), "example.com", Site("{\"not\":\"a list\"}")))
        assertEquals(noLinks, check(app(), "example.com", Site("<html>")))
    }

    @Test
    fun refusesRelyingPartiesThatArentSitesWithoutAsking() {
        val site = Site(links("com.example.shop", appCert))
        for (rpId in listOf("", "localhost", "192.168.1.1", "example.com/.well-known", "example.com:443", "exa mple.com", "-example.com", "example..com")) {
            assertEquals(rpId, Verdict.Refused(Refusal.BAD_RP_ID), check(app(), rpId, site))
        }
        assertEquals(emptyList<String>(), site.asked)
    }

    @Test
    fun asksASiteOnceForTheRequestAndTheScreenThatSignsIt() {
        var now = 0L
        val site = Site(links("com.example.shop", appCert))
        val check = CallerCheck(TrustedBrowsers(bundled), AssetLinks(site) { now })
        check.check(app(), "example.com")
        now += 60_000
        check.check(app(), "example.com")
        assertEquals(1, site.asked.size)
        now += 10 * 60_000
        check.check(app(), "example.com")
        assertEquals(2, site.asked.size)
        // A failed fetch isn't kept
        val down = Site(fails = true)
        val failing = CallerCheck(TrustedBrowsers(bundled), AssetLinks(down))
        failing.check(app(), "example.com")
        failing.check(app(), "example.com")
        assertEquals(2, down.asked.size)
    }

    // openspec: add-offline-mode, "Passkey sign-in to apps waits on Android"
    private fun offlineCheck(site: Site, offline: () -> Boolean) =
        CallerCheck(TrustedBrowsers(bundled), AssetLinks(OfflineAssetLinks(offline, site)))

    @Test
    fun refusesAnAppWithoutAskingItsSiteWhileOfflineModeIsOn() {
        val site = Site(links("com.example.shop", appCert))
        val verdict = offlineCheck(site) { true }.check(app(), "example.com")
        assertEquals(Verdict.Refused(Refusal.OFFLINE), verdict)
        assertEquals(emptyList<String>(), site.asked)
        assertTrue("the provider still offers its entry, whose screen says why", verdict.offers)
    }

    @Test
    fun answersATrustedBrowserWhileOfflineModeIsOn() {
        val site = Site(fails = true)
        val check = offlineCheck(site) { true }
        assertEquals(Verdict.Allowed("https://webauthn.io"), check.check(browser("com.android.chrome", chromeRelease), "webauthn.io"))
        assertEquals(Verdict.Refused(Refusal.UNTRUSTED_BROWSER), check.check(browser("com.example.fake", appCert), "webauthn.io"))
        assertEquals(emptyList<String>(), site.asked)
    }

    @Test
    fun asksTheSiteAsBeforeWhileOfflineModeIsOffAndAgainOnceItIsTurnedOff() {
        var offline = false
        val site = Site(links("com.example.shop", appCert))
        assertEquals(Verdict.Allowed(CallerCheck.appOrigin(app())), offlineCheck(site) { offline }.check(app(), "example.com"))
        assertEquals(listOf("example.com"), site.asked)

        // The refusal while offline isn't kept: the next request, back online, asks the site
        offline = true
        val check = offlineCheck(site) { offline }
        assertEquals(Verdict.Refused(Refusal.OFFLINE), check.check(app(), "example.org"))
        offline = false
        assertEquals(Verdict.Refused(Refusal.NOT_LISTED), check.check(app("com.example.other"), "example.org"))
        assertEquals(listOf("example.com", "example.org"), site.asked)
    }

    @Test
    fun tellsAFailedFetchFromOfflineMode() {
        val verdict = offlineCheck(Site(fails = true)) { false }.check(app(), "example.com")
        assertEquals(Verdict.Refused(Refusal.NO_ASSET_LINKS), verdict)
        assertTrue(!verdict.offers)
    }

    @Test
    fun readsTheOfflineSwitchAsTheAppWritesIt() {
        assertTrue(OfflineSetting.isOn("{\"on\":true}"))
        for (stored in listOf(null, "", "{}", "{\"on\":false}", "{\"on\":\"yes\"}", "[]", "true")) {
            assertTrue(stored ?: "nothing", !OfflineSetting.isOn(stored))
        }
        assertEquals("backmycodes_offline", OfflineSetting.KEY)
    }
}
