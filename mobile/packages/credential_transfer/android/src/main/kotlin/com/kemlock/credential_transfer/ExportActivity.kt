package com.kemlock.credential_transfer

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.credentials.providerevents.IntentHandler
import androidx.credentials.providerevents.exception.ImportCredentialsSystemErrorException
import androidx.credentials.providerevents.transfer.ImportCredentialsResponse
import androidx.credentials.providerevents.transfer.ProviderImportCredentialsRequest
import java.security.SecureRandom

/**
 * What the system's selector opens when the person picks a Kemlock entry in another app's import
 * (openspec: plan add-credential-exchange, design decision 11, task 8.4). It is exported, so any
 * app can start it: before it does anything it makes the two checks of [ExportCheck], the calling
 * package and the entry's secret id, and a request that fails either ends with a cancel and no Dart
 * is called. It has no screen of its own and reads nothing from the vault.
 *
 * A request that passes is held in [ExportRequests], and the app's own screen
 * (`ExportRequestActivity`, on the process's Flutter engine) is started for a result on top of this
 * one. There Dart waits for the vault to be unlocked, shows what would go, asks the owner and
 * answers through the plugin's channel: [answer] writes the CXF JSON to the content URI the
 * importer gave, through the library, and ends with `RESULT_OK`. Closing the screen, Back, or the
 * importer's task going away ends with a cancel. The JSON is passed to the library and not kept.
 * Only on Android 8 and later, and only while the `credential_export_enabled` resource is true, which the plugin's
 * build.gradle.kts makes from the define that switches the Dart side on.
 */
class ExportActivity : Activity(), ExportReplier {
    private var asked: ProviderImportCredentialsRequest? = null
    private var ended = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Made again after the process died: the request in memory is gone, and so is any answer
        if (savedInstanceState != null || Build.VERSION.SDK_INT < MIN_API) return refuse()
        // The caller first: the intent is whatever the caller made it, so it is not even parsed for one that
        // isn't the system's selector
        if (!ExportCheck.callerTrusted(callingPackage, ::isSystemApp)) return refuse()
        // Whatever the parse or the reads of its result throw, the request is refused, never crashed on
        val pending = try {
            accept()
        } catch (_: Exception) {
            null
        }
        if (pending == null) return refuse()
        ExportRequests.open(pending, this)
        startActivityForResult(Intent().setClassName(packageName, SCREEN).putExtra(EXTRA_REQUEST, pending.id), REQUEST_SCREEN)
    }

    /**
     * Parses the request and makes the entry check of [ExportCheck]; the request to hold, or null when it
     * isn't one. The caller has been checked by now. Throws what the library throws on an intent it can't read.
     */
    private fun accept(): PendingExport? {
        val request = IntentHandler.retrieveProviderImportCredentialsRequest(intent) ?: return null
        val verdict = ExportCheck.verdict(callingPackage, request.credId, ExportNonces(PreferencesNonceStore(this)), ::isSystemApp)
        if (verdict !is ExportVerdict.Allowed) return null
        // The importer names the URI the export is written to: never one of Kemlock's own providers
        val target = request.uri
        if (!ExportCheck.targetAllowed(target.scheme, target.authority, ownAuthorities())) return null
        val importer = request.callingAppInfo.packageName
        val pending = PendingExport(
            id = ExportNonces.randomHex(SecureRandom(), REQUEST_ID_BYTES),
            vaultId = verdict.vaultId,
            packageName = importer,
            label = labelOf(importer),
            types = request.request.credentialTypes,
        )
        asked = request
        return pending
    }

    /** The authority of every content provider this app declares, the library's and the plugins' included. */
    private fun ownAuthorities(): Set<String> {
        val info = packageManager.getPackageInfo(packageName, PackageManager.GET_PROVIDERS)
        return info.providers.orEmpty().flatMap { it.authority.orEmpty().split(';') }.filter { it.isNotEmpty() }.toSet()
    }

    /**
     * Whether [pkg] is part of the system image, updated or not. False for a package that can't be looked up: a
     * caller the phone can't vouch for is turned away. The plugin's manifest has a `<queries>` entry for the
     * selector's package, so that Android 11's package visibility never hides it.
     */
    private fun isSystemApp(pkg: String): Boolean = try {
        ExportCheck.isSystemApp(packageManager.getApplicationInfo(pkg, 0).flags)
    } catch (_: PackageManager.NameNotFoundException) {
        false
    } catch (_: RuntimeException) {
        false
    }

    /** The importer's name as the phone shows it; its package name when that can't be read. */
    private fun labelOf(importer: String): String = try {
        val info = packageManager.getApplicationInfo(importer, 0)
        packageManager.getApplicationLabel(info).toString().ifBlank { importer }
    } catch (_: PackageManager.NameNotFoundException) {
        importer
    } catch (_: RuntimeException) {
        importer
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        // Dart's answer ends this activity first; the screen going away on its own is a cancel
        if (requestCode == REQUEST_SCREEN && !ended) refuse()
    }

    override fun answer(json: String) {
        val request = asked
        if (ended || request == null) return
        ended = true
        try {
            IntentHandler.setImportCredentialsResponse(this, request.uri, intent, ImportCredentialsResponse(json))
        } catch (_: RuntimeException) {
            // The exception's text is left out: it could name what was being written
            IntentHandler.setImportCredentialsException(intent, ImportCredentialsSystemErrorException("The export could not be written"))
        }
        // RESULT_OK even for an exception: the system reads the intent's extras to tell
        setResult(RESULT_OK, intent)
        end()
    }

    override fun refuse() {
        if (ended) return
        ended = true
        setResult(RESULT_CANCELED)
        end()
    }

    private fun end() {
        ExportRequests.closed(this)
        // Whether answered or cancelled: nothing of the transfer stays in Kemlock's cache
        TransferFiles.deleteAfterExport(cacheDir)
        // The app's screen on top, if it is still up
        finishActivity(REQUEST_SCREEN)
        finish()
    }

    override fun onDestroy() {
        // Gone without an answer: the request goes with it
        ended = true
        ExportRequests.closed(this)
        // However the activity went, answered, cancelled, closed by the system or with its task: end() isn't the only
        // way here, and what the library left in Kemlock's cache must not outlive it
        TransferFiles.deleteAfterExport(cacheDir)
        super.onDestroy()
    }

    companion object {
        /** Android 8: the first the transfer works on. */
        const val MIN_API = 26

        /** The app's own screen on the process's engine (`app/exchange/ExportRequestActivity`). */
        const val SCREEN = "com.kemlock.app.exchange.ExportRequestActivity"

        const val EXTRA_REQUEST = "com.kemlock.app.extra.EXPORT_REQUEST"
        private const val REQUEST_SCREEN = 41
        private const val REQUEST_ID_BYTES = 16
    }
}
