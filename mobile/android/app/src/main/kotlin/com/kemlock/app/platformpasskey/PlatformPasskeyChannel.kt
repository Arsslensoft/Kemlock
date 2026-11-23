package com.kemlock.app.platformpasskey

import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.os.OutcomeReceiver
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONException
import org.json.JSONObject

/**
 * What the platform passkey sign-in needs to know without Android, so a unit test runs it: whether the phone has the
 * platform's Credential Manager, and which of Dart's error words a failure is. Dart builds the WebAuthn request
 * and reads the answer; this side only carries the two JSON strings.
 */
object PlatformPasskey {
    /** Credential Manager is part of the platform from Android 14 (API 34), with no Play services. */
    const val FIRST_SDK = 34

    fun supported(sdk: Int): Boolean = sdk >= FIRST_SDK

    const val TYPE_USER_CANCELED = "android.credentials.GetCredentialException.TYPE_USER_CANCELED"
    const val TYPE_NO_CREDENTIAL = "android.credentials.GetCredentialException.TYPE_NO_CREDENTIAL"

    /** The error code Dart reads for a failure of type [type]: `cancelled`, `noCredential` or `failed`. */
    fun errorCode(type: String?): String = when (type) {
        TYPE_USER_CANCELED -> "cancelled"
        TYPE_NO_CREDENTIAL -> "noCredential"
        else -> "failed"
    }

    // The keys and values of the bundles Credential Manager's providers read, which `androidx.credentials` writes:
    // the platform API takes the same bundles with no library.
    const val TYPE_PUBLIC_KEY = "androidx.credentials.TYPE_PUBLIC_KEY_CREDENTIAL"
    const val KEY_SUBTYPE = "androidx.credentials.BUNDLE_KEY_SUBTYPE"
    const val VALUE_SUBTYPE_GET = "androidx.credentials.BUNDLE_VALUE_SUBTYPE_GET_PUBLIC_KEY_CREDENTIAL_OPTION"
    const val KEY_REQUEST_JSON = "androidx.credentials.BUNDLE_KEY_REQUEST_JSON"
    const val KEY_PREFER_IMMEDIATE = "androidx.credentials.BUNDLE_KEY_PREFER_IMMEDIATELY_AVAILABLE_CREDENTIALS"
    const val KEY_RESPONSE_JSON = "androidx.credentials.BUNDLE_KEY_AUTHENTICATION_RESPONSE_JSON"

    /**
     * What is wrong with the WebAuthn request Dart built, or null when it is fine: it is a JSON object with a
     * challenge and a relying party id, and it asks for the `prf` extension's output for one input, which is what
     * opens the account. A request without them would sign nothing the server can use, so it is refused before the
     * credential provider shows a picker.
     */
    fun requestProblem(requestJson: String): String? {
        val request = try {
            JSONObject(requestJson)
        } catch (e: JSONException) {
            return "the request is not JSON"
        }
        if (request.optString("challenge").isEmpty()) return "the request has no challenge"
        if (request.optString("rpId").isEmpty()) return "the request has no relying party"
        val first = request.optJSONObject("extensions")?.optJSONObject("prf")?.optJSONObject("eval")?.optString("first")
        if (first.isNullOrEmpty()) return "the request does not ask for the prf output"
        return null
    }

    /** The entries of the bundle that carries [requestJson] to the providers: the request verbatim, and no shortcut. */
    fun requestData(requestJson: String): Map<String, Any> = mapOf(
        KEY_SUBTYPE to VALUE_SUBTYPE_GET,
        KEY_REQUEST_JSON to requestJson,
        KEY_PREFER_IMMEDIATE to false,
    )
}

/**
 * Signs in with a passkey held by the phone's credential provider, through the platform's Credential Manager
 * (Android 14 and later), for `lib/platform/platform_passkeys.dart`. The relying party must name this app in its
 * `/.well-known/assetlinks.json`, which Credential Manager checks itself; Dart checks it first so the way in is
 * offered only where it can work. No library and no Play services: the free build has it too.
 */
class PlatformPasskeyChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.kemlock.app/platform_passkeys")

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(
                    mapOf("supported" to PlatformPasskey.supported(Build.VERSION.SDK_INT), "package" to activity.packageName),
                )
                "get" -> get(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun get(call: MethodCall, result: MethodChannel.Result) {
        val requestJson = call.argument<String>("requestJson")
        if (requestJson.isNullOrEmpty()) {
            result.error("failed", "no request", null)
            return
        }
        // The SDK test is spelled out, not left to supported(), so lint sees getCredential below runs on 34 and later
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE || !PlatformPasskey.supported(Build.VERSION.SDK_INT)) {
            result.error("unsupported", "Credential Manager needs Android 14", null)
            return
        }
        val problem = PlatformPasskey.requestProblem(requestJson)
        if (problem != null) {
            result.error("failed", problem, null)
            return
        }
        getCredential(requestJson, result)
    }

    @RequiresApi(PlatformPasskey.FIRST_SDK)
    private fun getCredential(requestJson: String, result: MethodChannel.Result) {
        val manager = activity.getSystemService(android.credentials.CredentialManager::class.java)
        if (manager == null) {
            result.error("unsupported", "no Credential Manager", null)
            return
        }
        val data = Bundle().apply {
            for ((key, value) in PlatformPasskey.requestData(requestJson)) {
                when (value) {
                    is String -> putString(key, value)
                    is Boolean -> putBoolean(key, value)
                }
            }
        }
        val option = android.credentials.CredentialOption.Builder(PlatformPasskey.TYPE_PUBLIC_KEY, data, data).build()
        val request = android.credentials.GetCredentialRequest.Builder(Bundle()).addCredentialOption(option).build()
        manager.getCredential(
            activity,
            request,
            null,
            activity.mainExecutor,
            object : OutcomeReceiver<android.credentials.GetCredentialResponse, android.credentials.GetCredentialException> {
                override fun onResult(response: android.credentials.GetCredentialResponse) {
                    val json = response.credential.data.getString(PlatformPasskey.KEY_RESPONSE_JSON)
                    if (json.isNullOrEmpty()) {
                        result.error("failed", "the credential carried no response", null)
                    } else {
                        result.success(json)
                    }
                }

                override fun onError(error: android.credentials.GetCredentialException) {
                    result.error(PlatformPasskey.errorCode(error.type), error.message, null)
                }
            },
        )
    }
}
