package com.kemlock.app.autofill

import com.kemlock.app.passkeys.Caller
import com.kemlock.app.passkeys.TrustedBrowsers

/**
 * Which accounts a field belongs to. A website's host matches an account's domain when it is
 * that domain or under it, compared label by label: `gist.github.com` matches `github.com`,
 * and `github.com.evil.io` and `evilgithub.com` don't. A domain the app wrote with a leading
 * `=` is a host anyone can open a tenant under, and matches only itself. An app matches only
 * the accounts the person picked in it, with the same signing certificate.
 */
object Matching {
    /**
     * Where a fill request's fields are. A website only when [app], the app showing it, is on
     * the list of trusted [browsers] with its certificate: any app can name any website in the
     * structure it hands autofill, and taking its word would fill that site's code into it.
     * And only a website the browser loaded over `https` ([webScheme]): anyone on the network
     * can answer for a site over `http`, so such a page, or one whose scheme the browser doesn't
     * say, is nowhere Kemlock knows, and gets no account by name and no remembered pick. So is
     * a trusted browser's field with no website at all (about:blank, a data: page, the browser's
     * own screens): taken for the browser app, a pick remembered there would be offered on every
     * such page, whoever made it. Otherwise the app itself, by its original certificate, which
     * matches only the accounts picked in it; null when its certificates can't be read.
     */
    fun target(webDomain: String?, webScheme: String?, app: Caller?, browsers: TrustedBrowsers): Target? {
        if (app == null) return null
        if (browsers.trusts(app)) return if (webDomain != null && webScheme.equals("https", ignoreCase = true)) Target.web(webDomain) else null
        // The first signer when there are several, else the original certificate, which a rotation keeps
        val certificate = (if (app.multipleSigners) app.signers else app.lineage).firstOrNull() ?: return null
        return Target.App(app.packageName, certificate.joinToString("") { "%02x".format(it) })
    }

    fun hostMatches(host: String, domain: String): Boolean {
        val h = host.lowercase().trimEnd('.')
        if (h.isEmpty()) return false
        if (domain.startsWith("=")) return h == domain.substring(1)
        return h == domain || h.endsWith(".$domain")
    }

    fun matches(target: Target, domains: List<String>, picked: Boolean): Boolean = when (target) {
        is Target.Web -> picked || domains.any { hostMatches(target.host, it) }
        is Target.App -> picked
    }

    /** The accounts of [accounts] that belong to [target], given the person's [picks]. */
    fun <A> matching(
        target: Target?,
        accounts: List<A>,
        picks: List<Pick>,
        vault: (A) -> String,
        id: (A) -> String,
        domains: (A) -> List<String>,
    ): List<A> {
        if (target == null) return emptyList()
        val picked = picks.filter { it.target == target }.map { it.vault to it.account }.toSet()
        return accounts.filter { matches(target, domains(it), (vault(it) to id(it)) in picked) }
    }
}
