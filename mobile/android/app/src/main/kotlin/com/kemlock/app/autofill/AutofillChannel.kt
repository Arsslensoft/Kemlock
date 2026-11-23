package com.kemlock.app.autofill

import android.app.Activity
import android.content.ComponentName
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.autofill.AutofillManager
import androidx.annotation.RequiresApi
import androidx.biometric.BiometricManager
import androidx.core.net.toUri
import com.kemlock.app.R
import com.kemlock.app.passkeys.B64
import com.kemlock.app.passkeys.KemlockCredentialService
import com.kemlock.app.passkeys.PasskeyStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * The app's side of `com.kemlock.app/autofill` (lib/platform/autofill.dart): where autofill
 * stands, turning it on, and writing or removing a vault's copy; and for passkeys, where the
 * provider stands, its settings, the vault's inbox key and the passkeys waiting in its inbox.
 * Key work runs off the main thread, since making a StrongBox key can take seconds.
 */
class AutofillChannel(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "com.kemlock.app/autofill")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && Build.VERSION.SDK_INT < Build.VERSION_CODES.R) removeLeftovers()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // Codes are filled from Android 11 only (AutofillKey); passkeys need 14
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return when (call.method) {
                "status" -> result.success(mapOf("supported" to false, "enabled" to false, "biometrics" to false, "chromeNeedsSetting" to false))
                "passkeyStatus" -> result.success(mapOf("supported" to false, "enabled" to false))
                "turnOn", "openChromeSettings", "openPasskeySettings" -> result.success(false)
                "readInbox" -> result.success(emptyList<Any>())
                else -> result.success(null)
            }
        }
        handle(call, result)
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> background(result) { status() }
            "turnOn" -> result.success(turnOn())
            "openChromeSettings" -> result.success(openChromeSettings())
            "writeVault" -> background(result) {
                val vault = call.argument<String>("vault")!!
                val copy = call.argument<String>("copy")!!
                if (!hasBiometrics()) throw AutofillError("noBiometrics", "No strong biometrics are enrolled")
                try {
                    val takes = VaultTakes.fromMap(call.argument<Map<String, Any?>>("takes"))
                    AutofillStore(activity).writeVault(vault, copy, call.argument<String>("index"), takes)
                    // The inbox key while passkeys or saving logins are on; without it the vault's own records go too
                    val passkeys = PasskeyStore(activity)
                    passkeys.setInboxKey(vault, call.argument<String>("inboxKey")?.let(B64::decode))
                    // Passkeys off, saving logins on: the key stays, the passkeys the provider made go
                    if (takes != null && !takes.passkeys) passkeys.forgetCreated(vault)
                } catch (e: AutofillError) {
                    throw e
                } catch (e: Exception) {
                    throw AutofillError("writeFailed", e.message)
                }
                null
            }
            "passkeyStatus" -> background(result) { passkeyStatus() }
            "openPasskeySettings" -> result.success(openPasskeySettings())
            "readInbox" -> background(result) {
                PasskeyStore(activity).readInbox(call.argument<String>("vault")!!).map { (name, content) -> mapOf("name" to name, "content" to content) }
            }
            "clearInbox" -> background(result) {
                PasskeyStore(activity).clearInbox(call.argument<String>("vault")!!, call.argument<List<String>>("names").orEmpty())
                null
            }
            "removeVault" -> background(result) {
                val vault = call.argument<String>("vault")!!
                AutofillStore(activity).removeVault(vault)
                PasskeyStore(activity).removeVault(vault)
                null
            }
            "removeAll" -> background(result) {
                AutofillStore(activity).removeAll()
                PasskeyStore(activity).removeAll()
                null
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Android 8 to 10, once a process: removes the key and every vault's files a Kemlock from
     * before wrote there, whose key opened with the PIN too. Nothing fills from them any more.
     */
    @RequiresApi(Build.VERSION_CODES.O)
    private fun removeLeftovers() {
        if (leftoversRemoved) return
        leftoversRemoved = true
        worker.execute {
            try {
                AutofillStore(activity).removeAll()
                PasskeyStore(activity).removeAll()
            } catch (_: Exception) {
                // Tried again by the next screen
                leftoversRemoved = false
            }
        }
    }

    private class AutofillError(val code: String, message: String?) : Exception(message)

    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        worker.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: AutofillError) {
                main.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                main.post { result.error("failed", e.message, null) }
            }
        }
    }

    private fun hasBiometrics(): Boolean =
        BiometricManager.from(activity).canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS

    @RequiresApi(Build.VERSION_CODES.O)
    private fun status(): Map<String, Any> {
        val manager = activity.getSystemService(AutofillManager::class.java)
        val enabled = manager?.hasEnabledAutofillServices() == true
        return mapOf(
            "supported" to (manager?.isAutofillSupported == true),
            "enabled" to enabled,
            "biometrics" to hasBiometrics(),
            "chromeNeedsSetting" to (chromeUsesOwnAutofill() == true),
            // Android's save prompt keeps the logins forms send, on every version that autofills
            "savesPasswords" to (manager?.isAutofillSupported == true),
        )
    }

    /** Opens Android's screen for choosing the autofill service, with Kemlock offered. */
    @RequiresApi(Build.VERSION_CODES.O)
    private fun turnOn(): Boolean = try {
        activity.startActivity(Intent(Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE, "package:${activity.packageName}".toUri()))
        true
    } catch (_: Exception) {
        false
    }

    /**
     * Whether Chrome fills with its own passwords rather than asking the autofill service:
     * true or false from the content provider Chrome 135 and up has, null where it has none.
     */
    private fun chromeUsesOwnAutofill(): Boolean? {
        val uri = Uri.Builder()
            .scheme(ContentResolver.SCHEME_CONTENT)
            .authority("$CHROME.AutofillThirdPartyModeContentProvider")
            .path("autofill_third_party_mode")
            .build()
        return try {
            activity.contentResolver.query(uri, arrayOf(CHROME_COLUMN), null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst()) null else cursor.getInt(cursor.getColumnIndexOrThrow(CHROME_COLUMN)) == 0
            }
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Whether this phone takes passkeys from Kemlock (Android 14 and up, where the provider is
     * built in), and whether Kemlock is one of its enabled providers.
     */
    private fun passkeyStatus(): Map<String, Any> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE || !activity.resources.getBoolean(R.bool.passkeys_supported)) {
            return mapOf("supported" to false, "enabled" to false)
        }
        val manager = activity.getSystemService(android.credentials.CredentialManager::class.java)
        val enabled = try {
            manager?.isEnabledCredentialProviderService(ComponentName(activity, KemlockCredentialService::class.java)) == true
        } catch (_: Exception) {
            false
        }
        return mapOf("supported" to true, "enabled" to enabled)
    }

    /**
     * Opens the phone's settings for where passkeys are saved: the screen that offers Kemlock as
     * a provider, else the phone's settings. False below Android 14.
     */
    private fun openPasskeySettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return false
        for (intent in listOf(Intent(ACTION_CREDENTIAL_PROVIDER, "package:${activity.packageName}".toUri()), Intent(Settings.ACTION_SETTINGS))) {
            try {
                activity.startActivity(intent)
                return true
            } catch (_: Exception) {
                // The next one
            }
        }
        return false
    }

    /** Opens Chrome's settings, where "Autofill using another service" is. */
    private fun openChromeSettings(): Boolean = try {
        activity.startActivity(
            Intent(Intent.ACTION_APPLICATION_PREFERENCES)
                .addCategory(Intent.CATEGORY_DEFAULT)
                .addCategory(Intent.CATEGORY_APP_BROWSER)
                .addCategory(Intent.CATEGORY_PREFERENCE)
                .setPackage(CHROME),
        )
        true
    } catch (_: Exception) {
        false
    }

    companion object {
        @Volatile
        private var leftoversRemoved = false

        private const val CHROME = "com.android.chrome"
        private const val CHROME_COLUMN = "autofill_third_party_state"

        // Settings.ACTION_CREDENTIAL_PROVIDER, public from Android 15; Android 14 has the screen too,
        // and androidx's createSettingsPendingIntent opens it there by this name
        private const val ACTION_CREDENTIAL_PROVIDER = "android.settings.CREDENTIAL_PROVIDER"
    }
}
