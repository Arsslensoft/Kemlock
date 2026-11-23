package com.kemlock.app.passkeys

import android.content.Context
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.credentials.provider.CallingAppInfo
import com.kemlock.app.R

/**
 * The bundled list of trusted browsers, read once for the process: the passkey provider checks a
 * browser against it, and the autofill service the app that names a website.
 */
object BundledBrowsers {
    @Volatile
    private var shared: TrustedBrowsers? = null

    fun get(context: Context): TrustedBrowsers = shared ?: synchronized(this) {
        shared ?: run {
            val json = context.resources.openRawResource(R.raw.passkey_browsers).bufferedReader().use { it.readText() }
            TrustedBrowsers(json, includeUserdebug = Build.TYPE == "userdebug").also { shared = it }
        }
    }
}

/** The caller of a Credential Manager request, read for [CallerCheck], and the check the provider shares. */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
object CallingApps {
    /** Where the app keeps its storage keys, as `KemlockCredentialService` reads it. */
    private const val PREFERENCES = "CapacitorStorage"

    @Volatile
    private var shared: Pair<TrustedBrowsers, CallerCheck>? = null

    /** The bundled list and a check over it and the sites' asset links, made once for the process. */
    fun check(context: Context): Pair<TrustedBrowsers, CallerCheck> = shared ?: synchronized(this) {
        shared ?: run {
            val browsers = BundledBrowsers.get(context)
            // The app's storage, where the offline switch is written (preferences_backend.dart), read at each fetch
            val prefs = context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            val links = OfflineAssetLinks({ OfflineSetting.isOn(prefs.getString(OfflineSetting.KEY, null)) }, HttpsAssetLinks)
            (browsers to CallerCheck(browsers, AssetLinks(links))).also { shared = it }
        }
    }

    /**
     * [info] as a [Caller]. The origin a browser names comes only through androidx's `getOrigin`,
     * which checks the browser against the same list; when it refuses, the caller has none.
     */
    fun caller(info: CallingAppInfo, browsers: TrustedBrowsers): Caller {
        val signing = info.signingInfo
        val multiple = signing.hasMultipleSigners()
        val signers = signing.apkContentsSigners.orEmpty().map { PasskeyBytes.sha256(it.toByteArray()) }
        val lineage = if (multiple) emptyList() else signing.signingCertificateHistory.orEmpty().map { PasskeyBytes.sha256(it.toByteArray()) }
        val forWebsite = info.isOriginPopulated()
        val origin = if (!forWebsite) {
            null
        } else {
            try {
                info.getOrigin(browsers.json)
            } catch (_: IllegalStateException) {
                null
            } catch (_: IllegalArgumentException) {
                null
            }
        }
        return Caller(info.packageName, signers, lineage, multiple, forWebsite, origin)
    }

    /**
     * The relying party [info] asks for, [requestedRpId] or else the site a browser names, and
     * whether to answer it. Kemlock never answers itself.
     */
    fun verdict(context: Context, info: CallingAppInfo, requestedRpId: String?): Pair<String?, Verdict> {
        val (browsers, check) = check(context)
        val caller = caller(info, browsers)
        if (caller.packageName == context.packageName) return null to Verdict.Refused(Refusal.NOT_LISTED)
        val rpId = requestedRpId ?: caller.origin?.let(CallerCheck::hostOf) ?: return null to Verdict.Refused(Refusal.BAD_RP_ID)
        return rpId to check.check(caller, rpId)
    }
}
