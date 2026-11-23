package com.kemlock.app.autofill

import com.kemlock.app.passkeys.Caller
import com.kemlock.app.passkeys.TrustedBrowsers
import com.kemlock.app.passkeys.fingerprint
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MatchingTest {
    @Test
    fun matchesADomainAndItsSubdomains() {
        assertTrue(Matching.hostMatches("github.com", "github.com"))
        assertTrue(Matching.hostMatches("gist.github.com", "github.com"))
        assertTrue(Matching.hostMatches("WWW.GitHub.com.", "github.com"))
    }

    @Test
    fun neverMatchesLookAlikes() {
        for (host in listOf("evilgithub.com", "github.com.evil.io", "github.co", "githubcom", "notgithub.com", "")) {
            assertFalse(host, Matching.hostMatches(host, "github.com"))
        }
    }

    @Test
    fun matchesAHostAnyoneCanOpenATenantUnderOnlyExactly() {
        assertTrue(Matching.hostMatches("acme.okta.com", "=acme.okta.com"))
        assertFalse(Matching.hostMatches("evil.okta.com", "=okta.com"))
        assertFalse(Matching.hostMatches("evil.acme.okta.com", "=acme.okta.com"))
    }

    private val accounts = listOf(
        IndexAccount("v1", "gh", "GitHub", listOf("github.com")),
        IndexAccount("v1", "bank", "My bank", emptyList()),
        IndexAccount("v2", "gh2", "GitHub", listOf("github.com")),
    )

    private fun matching(target: Target?, picks: List<Pick> = emptyList()) =
        Matching.matching(target, accounts, picks, { it.vault }, { it.id }, { it.domains }).map { it.id }

    @Test
    fun findsEveryVaultsAccountsForAWebsite() {
        assertEquals(listOf("gh", "gh2"), matching(Target.web("github.com")))
        assertEquals(emptyList<String>(), matching(Target.web("example.com")))
        assertEquals(emptyList<String>(), matching(null))
    }

    @Test
    fun matchesAnAppOnlyByAPickWithTheSameCertificate() {
        val app = Target.App("com.bank.app", "aa11")
        val picks = listOf(Pick("v1", app, "bank"))
        assertEquals(emptyList<String>(), matching(app))
        assertEquals(listOf("bank"), matching(app, picks))
        assertEquals(emptyList<String>(), matching(Target.App("com.bank.app", "bb22"), picks))
        assertEquals(emptyList<String>(), matching(Target.App("com.bank.app", "aa11"), listOf(Pick("v2", app, "bank"))))
    }

    private val chromeCert = ByteArray(32) { 0x11 }
    private val otherCert = ByteArray(32) { 0x22 }
    private val browsers = TrustedBrowsers(
        """{"apps":[{"type":"android","info":{"package_name":"com.android.chrome",
            "signatures":[{"build":"release","cert_fingerprint_sha256":"${fingerprint(chromeCert)}"}]}}]}""",
    )

    private fun app(packageName: String, vararg certs: ByteArray, lineage: List<ByteArray> = certs.toList()) =
        Caller(packageName, certs.toList(), if (certs.size > 1) emptyList() else lineage, certs.size > 1, forWebsite = false, origin = null)

    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

    @Test
    fun takesTheWebsiteATrustedBrowserNames() {
        assertEquals(Target.web("github.com"), Matching.target("GitHub.com", "https", app("com.android.chrome", chromeCert), browsers))
        assertEquals(Target.web("github.com"), Matching.target("github.com", "HTTPS", app("com.android.chrome", chromeCert), browsers))
    }

    @Test
    fun knowsNoPlaceATrustedBrowserNamesNoWebsiteFor() {
        // about:blank, a data: page or the browser's own screens: not the browser as an app, where a pick would follow every such page
        val chrome = app("com.android.chrome", chromeCert)
        val picks = listOf(Pick("v1", Target.App("com.android.chrome", hex(chromeCert)), "bank"))
        for (scheme in listOf(null, "https", "data", "about")) {
            val target = Matching.target(null, scheme, chrome, browsers)
            assertNull(scheme, target)
            assertEquals(emptyList<String>(), matching(target, picks))
        }
    }

    @Test
    fun knowsNoWebsiteATrustedBrowserLoadedWithoutHttps() {
        val chrome = app("com.android.chrome", chromeCert)
        // Anyone on the network answers for github.com over http: no account by name, no remembered pick
        val picks = listOf(Pick("v1", Target.web("github.com"), "bank"))
        for (scheme in listOf("http", null, "", "ftp", "https ")) {
            val target = Matching.target("github.com", scheme, chrome, browsers)
            assertNull(scheme, target)
            assertEquals(emptyList<String>(), matching(target, picks))
        }
        assertEquals(listOf("gh", "bank", "gh2"), matching(Matching.target("github.com", "https", chrome, browsers), picks))
    }

    @Test
    fun matchesAnyOtherAppThatNamesAWebsiteAsItself() {
        val evil = Matching.target("github.com", "https", app("com.evil.app", otherCert), browsers)
        assertEquals(Target.App("com.evil.app", hex(otherCert)), evil)
        assertEquals(emptyList<String>(), matching(evil))
        // Chrome's package name, signed by someone else
        assertEquals(Target.App("com.android.chrome", hex(otherCert)), Matching.target("github.com", "https", app("com.android.chrome", otherCert), browsers))
        // Nothing to go by without the app's certificates
        assertNull(Matching.target("github.com", "https", null, browsers))
    }

    @Test
    fun namesAnAppByItsOriginalCertificate() {
        val rotated = app("com.bank.app", otherCert, lineage = listOf(chromeCert, otherCert))
        assertEquals(Target.App("com.bank.app", hex(chromeCert)), Matching.target(null, null, rotated, browsers))
        assertEquals(Target.App("com.bank.app", hex(otherCert)), Matching.target(null, null, app("com.bank.app", otherCert, chromeCert), browsers))
    }

    @Test
    fun matchesAWebsitePickOnlyOnItsHost() {
        val picks = listOf(Pick("v1", Target.web("login.mybank.example"), "bank"))
        assertEquals(listOf("bank"), matching(Target.web("login.mybank.example"), picks))
        assertEquals(emptyList<String>(), matching(Target.web("mybank.example"), picks))
    }

    // openspec: add-passwords, task 5.6: logins match as accounts do, by the domains the app wrote
    private val logins = listOf(
        LoginEntry("v1", "mail", "Larkspur Mail", "ada@example.org", listOf("larkspur.example")),
        LoginEntry("v1", "router", "Router", "admin", listOf("=192.168.1.1")),
        LoginEntry("v2", "work", "Larkspur Mail", "ada@work.example", listOf("larkspur.example")),
        LoginEntry("v1", "app", "Banking app", null, emptyList()),
    )

    private fun loginsFor(target: Target?, picks: List<Pick> = emptyList()) =
        Matching.matching(target, logins, picks, { it.vault }, { it.id }, { it.domains }).map { it.id }

    @Test
    fun findsEveryVaultsLoginsForASiteAndItsSubdomains() {
        assertEquals(listOf("mail", "work"), loginsFor(Target.web("larkspur.example")))
        assertEquals(listOf("mail", "work"), loginsFor(Target.web("accounts.larkspur.example")))
        for (host in listOf("larkspur.example.evil.test", "evillarkspur.example", "larkspur.exam")) {
            assertEquals(host, emptyList<String>(), loginsFor(Target.web(host)))
        }
    }

    @Test
    fun matchesALoginOnAnAddressOnlyExactly() {
        assertEquals(listOf("router"), loginsFor(Target.web("192.168.1.1")))
        assertEquals(emptyList<String>(), loginsFor(Target.web("10.192.168.1.1")))
    }

    @Test
    fun matchesALoginInAnAppOnlyByAPickWithTheSameCertificate() {
        val bank = Target.App("com.bank.app", "aa11")
        val picks = listOf(Pick("v1", bank, "app"))
        assertEquals(emptyList<String>(), loginsFor(bank))
        assertEquals(listOf("app"), loginsFor(bank, picks))
        // The same package signed by someone else gets nothing
        assertEquals(emptyList<String>(), loginsFor(Target.App("com.bank.app", "bb22"), picks))
        // An app naming a website the login is for gets nothing either: it is matched as itself
        assertEquals(emptyList<String>(), loginsFor(Target.App("com.evil.app", "cc33")))
    }
}
