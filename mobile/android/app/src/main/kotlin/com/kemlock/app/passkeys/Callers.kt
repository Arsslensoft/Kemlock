package com.kemlock.app.passkeys

import android.os.Build
import androidx.annotation.RequiresApi
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.URI
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import javax.net.ssl.HttpsURLConnection

/**
 * The app asking the provider for a passkey: androidx's `CallingAppInfo`, without Android's
 * types, so the JVM tests make their own.
 */
class Caller(
    val packageName: String,
    /** SHA-256 of each certificate the app is signed with now (`apkContentsSigners`), the first one first. */
    val signers: List<ByteArray>,
    /** With one signer, SHA-256 of each certificate of its rotation lineage, the original first. */
    val lineage: List<ByteArray>,
    /** Signed by several signers, each of which must be trusted. */
    val multipleSigners: Boolean,
    /** It asks on behalf of a website, as a browser does. */
    val forWebsite: Boolean,
    /** That website's origin, which androidx hands over only to a caller on the same list of trusted browsers. */
    val origin: String?,
)

/** Whether to answer a caller, and for which origin the client data says the request came from. */
sealed class Verdict {
    data class Allowed(val origin: String) : Verdict()

    data class Refused(val reason: Refusal) : Verdict()
}

enum class Refusal {
    /** A relying party id that isn't a domain, or a single label for an app. */
    BAD_RP_ID,

    /** It says it asks for a website, but isn't on the list of trusted browsers, with its certificate. */
    UNTRUSTED_BROWSER,

    /** A trusted browser, asking for a site the relying party id doesn't cover. */
    WRONG_SITE,

    /** An app whose site's asset links don't name it, with its certificate, for signing in. */
    NOT_LISTED,

    /** An app whose site's asset links couldn't be fetched or read. */
    NO_ASSET_LINKS,

    /** An app whose site's asset links weren't fetched, because offline mode is on. */
    OFFLINE,
}

/**
 * Whether the provider offers its entries for this verdict: when it would answer, and when only
 * offline mode kept it from checking the app. Then the entry opens a screen that says so, and
 * nothing is made or signed.
 */
val Verdict.offers: Boolean get() = this is Verdict.Allowed || this == Verdict.Refused(Refusal.OFFLINE)

/** SHA-256 fingerprints as lists and asset links write them, `AA:BB:…`, compared without case. */
internal fun fingerprint(digest: ByteArray): String = digest.joinToString(":") { "%02X".format(it) }

private fun normalized(fingerprint: String): String = fingerprint.trim().uppercase()

/**
 * The browsers that may ask for a website's passkeys: Google's list for Credential Manager
 * (https://www.gstatic.com/gpm-passkeys-privileged-apps/apps.json), bundled as
 * `res/raw/passkey_browsers.json` and refreshed each release by
 * `tool/passkeys/update_trusted_browsers.sh`. Read as androidx's `CallingAppInfo.getOrigin`
 * reads it: Android apps, by package name and SHA-256 of the signing certificate, with the
 * `userdebug` builds' certificates left out unless the phone runs one.
 */
class TrustedBrowsers(val json: String, includeUserdebug: Boolean = false) {
    private val apps: Map<String, Set<String>> = try {
        val list = JSONObject(json).getJSONArray("apps")
        (0 until list.length()).mapNotNull { list.optJSONObject(it) }
            .filter { it.optString("type") == "android" }
            .mapNotNull { it.optJSONObject("info") }
            .associate { info ->
                val signatures = info.optJSONArray("signatures") ?: JSONArray()
                info.optString("package_name") to (0 until signatures.length()).mapNotNull { signatures.optJSONObject(it) }
                    .filter { includeUserdebug || it.optString("build") != "userdebug" }
                    .mapNotNull { it.optString("cert_fingerprint_sha256").ifEmpty { null }?.let(::normalized) }
                    .toSet()
            }
    } catch (_: JSONException) {
        emptyMap()
    }

    /** The package names on the list. */
    val packages: Set<String> get() = apps.keys

    /**
     * Whether [caller] is on the list with its certificate: each signer when it has several, else
     * its original certificate, as androidx checks it before handing over the origin.
     */
    fun trusts(caller: Caller): Boolean {
        val listed = apps[caller.packageName] ?: return false
        return if (caller.multipleSigners) {
            caller.signers.isNotEmpty() && caller.signers.all { fingerprint(it) in listed }
        } else {
            caller.lineage.firstOrNull()?.let { fingerprint(it) in listed } == true
        }
    }
}

/** Fetches a site's `/.well-known/assetlinks.json`; throws [IOException] when it can't. */
fun interface AssetLinksSource {
    @Throws(IOException::class)
    fun fetch(host: String): String
}

/**
 * A site's Digital Asset Links, read for whether it names an app as one that signs in to it: a
 * statement with the relation `delegate_permission/common.get_login_creds` and the target
 * `android_app` with the app's package name and certificate. `handle_all_urls` is not enough: a
 * site hands an app its links without handing it its sign-ins. `include` statements aren't
 * followed, so the one request goes to the site being signed in to. Sites that list their apps
 * are kept for a few minutes, so the request the provider answers and the screen that signs it
 * fetch once.
 */
class AssetLinks(private val source: AssetLinksSource, private val clock: () -> Long = System::currentTimeMillis) {
    private val cache = ConcurrentHashMap<String, Pair<Long, List<AppStatement>>>()

    /** One `android_app` target a site names for signing in. */
    data class AppStatement(val packageName: String, val fingerprints: Set<String>)

    /**
     * Whether [host] names [caller] for signing in, with the certificate it is signed with now,
     * each of them when it has several. A certificate it was signed with before a rotation does
     * not count: a retired key is the one a site takes off its list, and the origin the app is
     * answered under names the current one. Throws [IOException] when the file can't be fetched,
     * and [JSONException] when it isn't asset links.
     */
    fun lists(host: String, caller: Caller): Boolean {
        val statements = statements(host).filter { it.packageName == caller.packageName }
        if (statements.isEmpty()) return false
        val listed = statements.flatMap { it.fingerprints }.toSet()
        return caller.signers.isNotEmpty() && caller.signers.all { fingerprint(it) in listed }
    }

    private fun statements(host: String): List<AppStatement> {
        val now = clock()
        cache[host]?.let { (at, statements) -> if (now - at in 0 until KEEP_MS) return statements }
        val statements = parse(source.fetch(host))
        cache[host] = now to statements
        return statements
    }

    companion object {
        private const val KEEP_MS = 5 * 60 * 1000L

        val RELATIONS = setOf("delegate_permission/common.get_login_creds")

        /** The app targets of an asset links file that may sign in. Throws [JSONException] for one that isn't a list. */
        fun parse(json: String): List<AppStatement> {
            val list = JSONArray(json)
            return (0 until list.length()).mapNotNull { list.optJSONObject(it) }.mapNotNull { statement ->
                val relations = statement.optJSONArray("relation") ?: return@mapNotNull null
                if ((0 until relations.length()).none { relations.optString(it) in RELATIONS }) return@mapNotNull null
                val target = statement.optJSONObject("target") ?: return@mapNotNull null
                if (target.optString("namespace") != "android_app") return@mapNotNull null
                val packageName = target.optString("package_name").ifEmpty { return@mapNotNull null }
                val prints = target.optJSONArray("sha256_cert_fingerprints") ?: return@mapNotNull null
                AppStatement(packageName, (0 until prints.length()).map { normalized(prints.optString(it)) }.filter { it.isNotEmpty() }.toSet())
            }
        }
    }
}

/** Thrown in place of fetching a site's asset links while offline mode is on. */
class OfflineException : IOException("Offline mode is on")

/**
 * [inner] behind Kemlock's offline mode (openspec: add-offline-mode, decision 7): while [offline]
 * says it is on, nothing is fetched and [OfflineException] is thrown, so an app is refused, with
 * that as the reason. A browser is checked against the bundled list and needs no fetch. A stale
 * answer is not used in its place: who may sign in is a security decision.
 */
class OfflineAssetLinks(private val offline: () -> Boolean, private val inner: AssetLinksSource) : AssetLinksSource {
    override fun fetch(host: String): String {
        if (offline()) throw OfflineException()
        return inner.fetch(host)
    }
}

/**
 * Whether the app's storage says offline mode is on: the value of `backmycodes_offline`, which
 * `lib/platform/network.dart` writes as `{"on":true}` and removes when off. Anything else is off.
 */
object OfflineSetting {
    const val KEY = "backmycodes_offline"

    fun isOn(stored: String?): Boolean = try {
        stored != null && JSONObject(stored).opt("on") == true
    } catch (_: JSONException) {
        false
    }
}

/** The site's asset links over HTTPS: no redirects, a short wait, and at most [MAX_BYTES]. */
object HttpsAssetLinks : AssetLinksSource {
    private const val MAX_BYTES = 256 * 1024
    private const val TIMEOUT_MS = 5000

    override fun fetch(host: String): String {
        val connection = URL("https", host, "/.well-known/assetlinks.json").openConnection() as HttpsURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = TIMEOUT_MS
            connection.readTimeout = TIMEOUT_MS
            connection.useCaches = false
            connection.setRequestProperty("Accept", "application/json")
            if (connection.responseCode != HttpsURLConnection.HTTP_OK) throw IOException("HTTP ${connection.responseCode} from $host")
            val out = ByteArrayOutputStream()
            connection.inputStream.use { input ->
                val buffer = ByteArray(8192)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    out.write(buffer, 0, read)
                    if (out.size() > MAX_BYTES) throw IOException("The asset links of $host are too large")
                }
            }
            return out.toString("UTF-8")
        } finally {
            connection.disconnect()
        }
    }
}

/**
 * Who gets an answer (openspec: add-vault-items, the passkeys spec): a browser only when it is
 * on the list of trusted browsers, for a site the relying party covers; an app only when the
 * relying party's site names it in its asset links. Anyone else is refused before anything is
 * offered, made or signed.
 */
@RequiresApi(Build.VERSION_CODES.O)
class CallerCheck(private val browsers: TrustedBrowsers, private val assetLinks: AssetLinks) {
    fun check(caller: Caller, rpId: String): Verdict {
        val rp = rpId.lowercase()
        if (!domain.matches(rp)) return Verdict.Refused(Refusal.BAD_RP_ID)
        if (caller.forWebsite) {
            val origin = caller.origin
            if (origin == null || !browsers.trusts(caller)) return Verdict.Refused(Refusal.UNTRUSTED_BROWSER)
            return if (originFits(origin, rp)) Verdict.Allowed(origin) else Verdict.Refused(Refusal.WRONG_SITE)
        }
        if (!rp.contains('.') || caller.signers.isEmpty()) return Verdict.Refused(Refusal.BAD_RP_ID)
        val listed = try {
            assetLinks.lists(rp, caller)
        } catch (_: OfflineException) {
            return Verdict.Refused(Refusal.OFFLINE)
        } catch (_: IOException) {
            return Verdict.Refused(Refusal.NO_ASSET_LINKS)
        } catch (_: JSONException) {
            return Verdict.Refused(Refusal.NO_ASSET_LINKS)
        }
        return if (listed) Verdict.Allowed(appOrigin(caller)) else Verdict.Refused(Refusal.NOT_LISTED)
    }

    companion object {
        // Lowercase labels, the last starting with a letter, so no address is taken for a site
        private val domain = Regex("^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)*[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$")

        /** The origin WebAuthn gives an Android app: its current certificate's SHA-256, base64url. */
        fun appOrigin(caller: Caller): String = "android:apk-key-hash:" + B64.url(caller.signers.first())

        /** The host of a website's [origin], or null for one that isn't `https:` (or `http:` on localhost). */
        fun hostOf(origin: String): String? = try {
            val uri = URI(origin)
            val host = uri.host?.lowercase()?.trimEnd('.')
            when {
                host.isNullOrEmpty() || uri.rawUserInfo != null -> null
                uri.scheme == "https" -> host
                uri.scheme == "http" && host == "localhost" -> host
                else -> null
            }
        } catch (_: Exception) {
            null
        }

        /** Whether a website at [origin] may use passkeys of [rpId]: its host is that domain or under it. */
        fun originFits(origin: String, rpId: String): Boolean {
            val host = hostOf(origin) ?: return false
            return host == rpId || host.endsWith(".$rpId")
        }
    }
}
