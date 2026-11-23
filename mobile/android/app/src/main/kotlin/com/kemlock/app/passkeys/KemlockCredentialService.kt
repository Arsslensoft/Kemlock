package com.kemlock.app.passkeys

import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.os.CancellationSignal
import android.os.OutcomeReceiver
import androidx.annotation.RequiresApi
import androidx.credentials.exceptions.ClearCredentialException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.provider.AuthenticationAction
import androidx.credentials.provider.BeginCreateCredentialRequest
import androidx.credentials.provider.BeginCreateCredentialResponse
import androidx.credentials.provider.BeginCreatePublicKeyCredentialRequest
import androidx.credentials.provider.BeginGetCredentialRequest
import androidx.credentials.provider.BeginGetCredentialResponse
import androidx.credentials.provider.BeginGetPublicKeyCredentialOption
import androidx.credentials.provider.CreateEntry
import androidx.credentials.provider.CredentialProviderService
import androidx.credentials.provider.ProviderClearCredentialStateRequest
import androidx.credentials.provider.PublicKeyCredentialEntry
import com.kemlock.app.R
import com.kemlock.app.autofill.AutofillKey
import com.kemlock.app.autofill.AutofillStore
import java.time.Instant
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Kemlock as a passkey provider (design decision 6), from Android 14. It never opens the vault
 * and nothing here needs biometrics: a request to save a passkey gets one entry per vault whose
 * passkeys are on, the vault used last first, and a sign-in request an entry per passkey of the
 * indexes and the provider's own records whose relying party is exactly the request's. The caller
 * is checked first ([CallerCheck]); one Kemlock doesn't answer gets no entry. Each entry opens
 * [PasskeyCreateActivity] or [PasskeyGetActivity], which ask for biometrics.
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class KemlockCredentialService : CredentialProviderService() {
    // Asset links come over the network, and StrongBox can be slow
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }

    override fun onBeginCreateCredentialRequest(
        request: BeginCreateCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<BeginCreateCredentialResponse, CreateCredentialException>,
    ) {
        worker.execute {
            val response = try {
                beginCreate(request)
            } catch (_: Exception) {
                BeginCreateCredentialResponse()
            }
            if (!cancellationSignal.isCanceled) callback.onResult(response)
        }
    }

    override fun onBeginGetCredentialRequest(
        request: BeginGetCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<BeginGetCredentialResponse, GetCredentialException>,
    ) {
        worker.execute {
            val response = try {
                beginGet(request)
            } catch (_: Exception) {
                BeginGetCredentialResponse()
            }
            if (!cancellationSignal.isCanceled) callback.onResult(response)
        }
    }

    // Kemlock keeps no sign-in state of its own to clear
    override fun onClearCredentialStateRequest(
        request: ProviderClearCredentialStateRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<Void?, ClearCredentialException>,
    ) = callback.onResult(null)

    private fun beginCreate(request: BeginCreateCredentialRequest): BeginCreateCredentialResponse {
        val none = BeginCreateCredentialResponse()
        if (request !is BeginCreatePublicKeyCredentialRequest) return none
        val info = request.callingAppInfo ?: return none
        val options = try {
            CreationOptions.parse(request.requestJson)
        } catch (_: BadRequestException) {
            return none
        }
        if (!options.acceptsEs256) return none
        val store = PasskeyStore(this)
        val autofill = AutofillStore(this)
        // A vault's inbox key may be there for its logins alone
        val vaults = store.vaults().filter(autofill::takesPasskeys)
        if (vaults.isEmpty()) return none
        if (!CallingApps.verdict(this, info, options.rpId).second.offers) return none

        val counts = (autofill.indexPasskeys() + store.created()).groupingBy { it.vault }.eachCount()
        val prefs = getSharedPreferences(PREFERENCES, MODE_PRIVATE)
        val response = BeginCreateCredentialResponse.Builder()
        for (vault in PasskeyMatching.byLastUse(vaults, autofill::lastWritten)) {
            val name = PasskeyMatching.vaultName(prefs.getString(PasskeyMatching.configKey(vault), null))
                ?: getString(R.string.passkeys_vault_default)
            response.addCreateEntry(
                CreateEntry.Builder(name, pendingIntent(PasskeyCreateActivity.intent(this, vault)))
                    .setPublicKeyCredentialCount(counts[vault] ?: 0)
                    .setLastUsedTime(autofill.lastWritten(vault)?.let(Instant::ofEpochMilli))
                    .setIcon(icon())
                    .build(),
            )
        }
        return response.build()
    }

    private fun beginGet(request: BeginGetCredentialRequest): BeginGetCredentialResponse {
        val none = BeginGetCredentialResponse()
        val info = request.callingAppInfo ?: return none
        val options = request.beginGetCredentialOptions.filterIsInstance<BeginGetPublicKeyCredentialOption>()
        if (options.isEmpty()) return none
        val held = AutofillStore(this).indexPasskeys() + PasskeyStore(this).created()
        if (held.isEmpty()) return none

        val response = BeginGetCredentialResponse.Builder()
        var locked = false
        for (option in options) {
            val wanted = try {
                RequestOptions.parse(option.requestJson)
            } catch (_: BadRequestException) {
                continue
            }
            // A site Kemlock holds nothing for isn't asked for its asset links
            if (wanted.rpId != null && PasskeyMatching.matching(wanted.rpId, wanted.allowed, held).isEmpty()) continue
            val (rpId, verdict) = CallingApps.verdict(this, info, wanted.rpId)
            if (rpId == null || !verdict.offers) continue
            val matches = PasskeyMatching.matching(rpId, wanted.allowed, held)
            if (matches.isEmpty()) continue
            // Biometrics changed: nothing opens until the app is opened, which the action says
            if (!AutofillKey.isValid()) {
                locked = true
                continue
            }
            for (passkey in matches) {
                response.addCredentialEntry(
                    PublicKeyCredentialEntry.Builder(this, passkey.name, pendingIntent(PasskeyGetActivity.intent(this, passkey.vault, passkey.credentialId)), option)
                        .setDisplayName(passkey.userDisplayName)
                        .setIcon(icon())
                        .build(),
                )
            }
        }
        if (locked) {
            response.addAuthenticationAction(AuthenticationAction(getString(R.string.passkeys_reopen_action), pendingIntent(PasskeyGetActivity.reopenIntent(this))))
        }
        return response.build()
    }

    private fun icon(): Icon = Icon.createWithResource(this, R.mipmap.ic_launcher)

    // Mutable, so the system can add the request the screen reads; explicit, so only Kemlock's screen opens
    private fun pendingIntent(intent: Intent): PendingIntent =
        PendingIntent.getActivity(this, nextRequestCode(), intent, PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    companion object {
        /** Where the app keeps its storage keys (preferences_backend.dart), read here for vault names only. */
        private const val PREFERENCES = "CapacitorStorage"
        private var requestCode = 0

        @Synchronized
        private fun nextRequestCode(): Int = ++requestCode
    }
}
