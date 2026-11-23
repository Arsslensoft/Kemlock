package com.kemlock.app.passkeys

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.annotation.RequiresApi
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.CreateCredentialUnknownException
import androidx.credentials.exceptions.domerrors.EncodingError
import androidx.credentials.exceptions.domerrors.InvalidStateError
import androidx.credentials.exceptions.domerrors.NotSupportedError
import androidx.credentials.exceptions.domerrors.SecurityError
import androidx.credentials.exceptions.publickeycredential.CreatePublicKeyCredentialDomException
import androidx.credentials.provider.PendingIntentHandler
import com.kemlock.app.R
import com.kemlock.app.autofill.AutofillKey
import com.kemlock.app.autofill.AutofillStore

/**
 * Saves a new passkey to the vault the person picked (design decision 6): the request is read,
 * an algorithm other than ES256 is refused, the caller is checked, the person passes
 * biometrics, a credential the site excludes is refused as already registered, and then the key
 * is made, written to the vault's inbox and sealed to the autofill key, and the site gets its
 * response. Cancelling at any point saves nothing.
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class PasskeyCreateActivity : PasskeyActivity() {
    private lateinit var store: PasskeyStore

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = PasskeyStore(this)
        if (savedInstanceState != null) return finish()
        val provider = PendingIntentHandler.retrieveProviderCreateCredentialRequest(intent) ?: return finish()
        val request = provider.callingRequest as? CreatePublicKeyCredentialRequest
            ?: return fail(CreateCredentialUnknownException("Kemlock saves passkeys only"))
        val vault = intent.getStringExtra(EXTRA_VAULT) ?: return finish()
        val options = try {
            CreationOptions.parse(request.requestJson)
        } catch (e: BadRequestException) {
            return fail(CreatePublicKeyCredentialDomException(EncodingError(), e.message))
        }
        if (!options.acceptsEs256) return fail(CreatePublicKeyCredentialDomException(NotSupportedError(), "Kemlock makes ES256 passkeys only"))
        if (store.inboxKey(vault) == null || !AutofillStore(this).takesPasskeys(vault)) return showMessage(getString(R.string.passkeys_off))

        background({ CallingApps.verdict(this, provider.callingAppInfo, options.rpId) }) { result ->
            val (rpId, verdict) = result.getOrElse { null to Verdict.Refused(Refusal.NO_ASSET_LINKS) }
            when {
                // Offline mode kept Kemlock from asking the site which apps are its own
                rpId != null && verdict == Verdict.Refused(Refusal.OFFLINE) -> showMessage(getString(R.string.passkeys_offline, rpId))
                rpId == null || verdict !is Verdict.Allowed -> fail(CreatePublicKeyCredentialDomException(SecurityError(), "Kemlock doesn't answer this caller for ${rpId ?: "this site"}"))
                else -> prompt(getString(R.string.passkeys_create_title), rpId) { create(vault, options, rpId, verdict.origin) }
            }
        }
    }

    private fun create(vault: String, options: CreationOptions, rpId: String, origin: String) {
        val held = (AutofillStore(this).indexPasskeys() + store.created()).filter { it.rpId == rpId }
            .mapNotNull { runCatching { B64.fromUrl(it.credentialId) }.getOrNull() }
        if (options.excluded.any { excluded -> held.any { it.contentEquals(excluded) } }) {
            return fail(CreatePublicKeyCredentialDomException(InvalidStateError(), "Kemlock already holds a passkey the site excludes"))
        }
        background({
            val created = PasskeyResponses.create(options, rpId, origin, System.currentTimeMillis())
            hardwareKey()
            store.save(vault, created.record)
            created.json
        }) { result ->
            result.fold(
                onSuccess = { json ->
                    val data = Intent()
                    PendingIntentHandler.setCreateCredentialResponse(data, CreatePublicKeyCredentialResponse(json))
                    setResult(Activity.RESULT_OK, data)
                    finish()
                },
                onFailure = { showMessage(getString(R.string.passkeys_save_failed)) },
            )
        }
    }

    /**
     * Makes sure the autofill key can take the provider's own record: a key that biometrics
     * changed under opens nothing written before, so it all goes, as when the app writes a copy.
     */
    private fun hardwareKey() {
        try {
            if (AutofillKey.isValid()) return
            AutofillStore(this).removeAll()
            AutofillKey.create()
        } catch (_: Exception) {
            // The inbox file is enough to bring the passkey into the vault
        }
    }

    override fun cancelled() = fail(CreateCredentialCancellationException("Cancelled"))

    private fun fail(error: CreateCredentialException) {
        val data = Intent()
        PendingIntentHandler.setCreateCredentialException(data, error)
        setResult(Activity.RESULT_OK, data)
        finish()
    }

    companion object {
        fun intent(context: Context, vault: String): Intent = Intent(context, PasskeyCreateActivity::class.java).putExtra(EXTRA_VAULT, vault)
    }
}
