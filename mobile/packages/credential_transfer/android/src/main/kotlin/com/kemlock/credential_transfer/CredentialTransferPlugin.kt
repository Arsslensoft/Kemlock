package com.kemlock.credential_transfer

import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.credentials.CredentialManagerCallback
import androidx.credentials.providerevents.ProviderEventsManager
import androidx.credentials.providerevents.exception.ClearExportException
import androidx.credentials.providerevents.exception.ImportCredentialsException
import androidx.credentials.providerevents.exception.RegisterExportException
import androidx.credentials.providerevents.transfer.ClearExportRequest
import androidx.credentials.providerevents.transfer.ClearExportResponse
import androidx.credentials.providerevents.transfer.ExportEntry
import androidx.credentials.providerevents.transfer.ImportCredentialsRequest
import androidx.credentials.providerevents.transfer.KnownExtensions
import androidx.credentials.providerevents.transfer.ProviderImportCredentialsResponse
import androidx.credentials.providerevents.transfer.RegisterExportRequest
import androidx.credentials.providerevents.transfer.RegisterExportResponse
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * Credential Exchange's import on Android (openspec: plan add-credential-exchange, design decision
 * 8): `ProviderEventsManager.importCredentials` opens the system's list of apps that can export,
 * and answers the CXF JSON of the one the person picked. The data travels through a temporary file
 * in this app's cache, which the library makes and reads and which is deleted once the answer is in
 * ([TransferFiles]); Dart is given the string, never a path.
 * It is registered in every build that has this package, which is the store build's alone.
 *
 * The request names the credential types Dart sends, which filter the list, and the `shared`
 * extension, which is the one extension Kemlock reads. It starts only on Dart's call, which a
 * person's tap makes: nothing here is answered for an app that asks.
 */
class CredentialTransferPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    // Shared with the exported activity, which must not clear the transfer folder under a running import
    private var importing: Boolean
        get() = TransferFiles.importing
        set(value) {
            TransferFiles.importing = value
        }
    private val main = Handler(Looper.getMainLooper())

    private var context: Context? = null
    private val background = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        val made = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
        channel = made
        // A request that arrives while Dart runs is pushed; one that arrived before is asked for
        ExportRequests.onRequest = { request -> made.invokeMethod("exportRequested", request.toMap()) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        ExportRequests.onRequest = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(Build.VERSION.SDK_INT >= MIN_API)
            "importCredentials" -> importCredentials(call, result)
            "registerExports" -> registerExports(call, result)
            "clearExports" -> clearExports(result)
            "clearRegisteredExports" -> clearRegisteredExports(result)
            "pendingExport" -> result.success(ExportRequests.pending()?.toMap())
            "answerExport" -> {
                // The JSON is handed on and not kept; a call without both is refused
                val id = call.argument<String>("id")
                val json = call.argument<String>("json")
                if (id == null || json == null) result.error(ExportFailure.BAD_REQUEST, null, null) else answerExport(id, json, result)
            }
            "refuseExport" -> result.success(call.argument<String>("id")?.let { ExportRequests.refuse(it) } ?: false)
            else -> result.notImplemented()
        }
    }

    private fun answerExport(id: String, json: String, result: MethodChannel.Result) {
        if (ExportRequests.answer(id, json)) result.success(null) else result.error(ExportFailure.GONE, null, null)
    }

    /**
     * Registers an export entry for each vault Dart lists, so that the system's selector offers
     * Kemlock in other apps' imports (task 8.4). Each entry gets a new secret id made here
     * ([ExportNonces]), which Dart never sees and which is kept, hashed, only once the system has
     * the entries. An entry names the vault and the credential types Kemlock writes, and nothing
     * of what is in it. An empty list clears every entry.
     */
    private fun registerExports(call: MethodCall, reply: MethodChannel.Result) {
        val app = context ?: return reply.error(ExportFailure.NO_CONTEXT, null, null)
        if (Build.VERSION.SDK_INT < ExportActivity.MIN_API) return reply.error(ImportFailure.UNAVAILABLE, null, null)
        val entries = call.argument<List<Map<String, Any?>>>("entries").orEmpty()
        val types = call.argument<List<String>>("types").orEmpty().toSet()
        val vaults = entries.mapNotNull { entry -> (entry["vaultId"] as? String)?.takeIf { VaultIds.valid(it) }?.let { it to entry["account"] as? String } }
        if (vaults.isEmpty()) return clearExports(reply)
        if (types.isEmpty()) return reply.error(ExportFailure.BAD_REQUEST, null, null)
        val nonces = ExportNonces(PreferencesNonceStore(app))
        val issued = nonces.issue(vaults.map { it.first })
        val label = app.applicationInfo.loadLabel(app.packageManager)
        // create() reads the library's assets: off the main thread
        background.execute {
            try {
                val exports = vaults.map { (vault, account) ->
                    ExportEntry(
                        id = issued.getValue(vault),
                        accountDisplayName = account,
                        userDisplayName = label,
                        icon = ExportIcon.of(app),
                        supportedCredentialTypes = types,
                    )
                }
                val request = RegisterExportRequest.create(app, exports)
                ProviderEventsManager.create(app).registerExportAsync(
                    request,
                    Executor { main.post(it) },
                    object : CredentialManagerCallback<RegisterExportResponse, RegisterExportException> {
                        override fun onResult(result: RegisterExportResponse) {
                            nonces.commit(issued)
                            reply.success(null)
                        }

                        override fun onError(e: RegisterExportException) {
                            // The exception's message is left out: only that it failed is told
                            reply.error(ExportFailure.REGISTER, null, null)
                        }
                    },
                )
            } catch (_: RuntimeException) {
                main.post { reply.error(ExportFailure.REGISTER, null, null) }
            }
        }
    }

    /**
     * Takes Kemlock out of other apps' lists, and forgets every secret id, only when an entry is registered (a
     * build with export on registered one); otherwise it does nothing at all. What a build with export off calls
     * once, so that a release that had export on and is switched back off stops being offered. Replies false when
     * nothing was registered, and as clearExports does otherwise.
     */
    private fun clearRegisteredExports(reply: MethodChannel.Result) {
        val app = context ?: return reply.error(ExportFailure.NO_CONTEXT, null, null)
        if (!ExportNonces(PreferencesNonceStore(app)).any()) return reply.success(false)
        clearExports(reply)
    }

    /** Takes Kemlock out of other apps' lists, and forgets every secret id. */
    private fun clearExports(reply: MethodChannel.Result) {
        val app = context ?: return reply.error(ExportFailure.NO_CONTEXT, null, null)
        if (Build.VERSION.SDK_INT < ExportActivity.MIN_API) return reply.success(null)
        // Forgotten first: whatever the system still lists is answered by nothing
        ExportNonces(PreferencesNonceStore(app)).clear()
        try {
            ProviderEventsManager.create(app).clearExportAsync(
                ClearExportRequest(),
                Executor { main.post(it) },
                object : CredentialManagerCallback<ClearExportResponse, ClearExportException> {
                    override fun onResult(result: ClearExportResponse) = reply.success(null)

                    override fun onError(e: ClearExportException) = reply.error(ExportFailure.REGISTER, null, null)
                },
            )
        } catch (_: RuntimeException) {
            reply.error(ExportFailure.REGISTER, null, null)
        }
    }

    private fun importCredentials(call: MethodCall, reply: MethodChannel.Result) {
        val host = activity ?: return reply.error(ImportFailure.NO_ACTIVITY, null, null)
        if (Build.VERSION.SDK_INT < MIN_API) return reply.error(ImportFailure.UNAVAILABLE, null, null)
        if (importing) return reply.error(ImportFailure.BUSY, null, null)
        val types = call.argument<List<String>>("types").orEmpty().toSet()
        // The library refuses an empty set of types
        if (types.isEmpty()) return reply.error(ImportFailure.BAD_REQUEST, null, null)
        importing = true
        try {
            val request = ImportCredentialsRequest(credentialTypes = types, knownExtensions = setOf(KnownExtensions.KNOWN_EXTENSION_SHARED))
            ProviderEventsManager.create(host).importCredentialsAsync(
                host,
                request,
                null,
                Executor { main.post(it) },
                object : CredentialManagerCallback<ProviderImportCredentialsResponse, ImportCredentialsException> {
                    override fun onResult(result: ProviderImportCredentialsResponse) {
                        importing = false
                        // The JSON is in memory now: the plain copy in the cache is deleted before Dart is told
                        TransferFiles.delete(host.cacheDir)
                        reply.success(result.response.responseJson)
                    }

                    override fun onError(e: ImportCredentialsException) {
                        importing = false
                        TransferFiles.delete(host.cacheDir)
                        // The exception's message is left out: only its kind is told
                        val code = ImportFailure.codeOf(e)
                        if (code == null) reply.success(null) else reply.error(code, null, null)
                    }
                },
            )
        } catch (_: RuntimeException) {
            importing = false
            reply.error(ImportFailure.UNKNOWN, null, null)
        }
    }

    private companion object {
        const val CHANNEL = "com.kemlock.app/credential_transfer"

        /** Android 8: the first the transfer works on. */
        const val MIN_API = 26
    }
}
