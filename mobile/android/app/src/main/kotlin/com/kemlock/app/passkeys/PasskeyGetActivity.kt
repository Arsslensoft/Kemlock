package com.kemlock.app.passkeys

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.annotation.RequiresApi
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.GetCredentialUnknownException
import androidx.credentials.exceptions.NoCredentialException
import androidx.credentials.exceptions.domerrors.EncodingError
import androidx.credentials.exceptions.domerrors.SecurityError
import androidx.credentials.exceptions.publickeycredential.GetPublicKeyCredentialDomException
import androidx.credentials.provider.PendingIntentHandler
import com.kemlock.app.R
import com.kemlock.app.autofill.AutofillKey
import com.kemlock.app.autofill.AutofillStore
import com.kemlock.app.autofill.KeyInvalidatedException
import com.kemlock.app.autofill.PasskeyEntry

/**
 * Signs a sign-in with the passkey the person picked: the caller is checked again, the person
 * passes biometrics, the vault's copy and the provider's own records are opened with the autofill
 * key, and the passkey signs, if it is still there for this site and the request allows it. When
 * biometrics changed since the vault was last opened, nothing opens, and the screen says to open
 * Kemlock once.
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class PasskeyGetActivity : PasskeyActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return finish()
        reopenOnly = intent.getBooleanExtra(EXTRA_REOPEN, false)
        if (reopenOnly || !AutofillKey.isValid()) return invalidated()
        val provider = PendingIntentHandler.retrieveProviderGetCredentialRequest(intent) ?: return finish()
        val option = provider.credentialOptions.filterIsInstance<GetPublicKeyCredentialOption>().firstOrNull()
            ?: return fail(GetCredentialUnknownException("Kemlock signs in with passkeys only"))
        val vault = intent.getStringExtra(EXTRA_VAULT) ?: return finish()
        val credentialId = intent.getStringExtra(EXTRA_CREDENTIAL) ?: return finish()
        val options = try {
            RequestOptions.parse(option.requestJson)
        } catch (e: BadRequestException) {
            return fail(GetPublicKeyCredentialDomException(EncodingError(), e.message))
        }

        background({ CallingApps.verdict(this, provider.callingAppInfo, options.rpId) }) { result ->
            val (rpId, verdict) = result.getOrElse { null to Verdict.Refused(Refusal.NO_ASSET_LINKS) }
            when {
                // Offline mode kept Kemlock from asking the site which apps are its own
                rpId != null && verdict == Verdict.Refused(Refusal.OFFLINE) -> showMessage(getString(R.string.passkeys_offline, rpId))
                rpId == null || verdict !is Verdict.Allowed -> fail(GetPublicKeyCredentialDomException(SecurityError(), "Kemlock doesn't answer this caller for ${rpId ?: "this site"}"))
                else -> prompt(getString(R.string.passkeys_get_title), rpId) {
                    // The hash of its own client data is a browser's to give: one whose origin Android handed over
                    val browsersHash = option.clientDataHash?.takeIf { provider.callingAppInfo.isOriginPopulated() }
                    sign(vault, credentialId, rpId, options, verdict.origin, browsersHash)
                }
            }
        }
    }

    private fun sign(vault: String, credentialId: String, rpId: String, options: RequestOptions, origin: String, clientDataHash: ByteArray?) {
        background({
            val passkey = find(vault, credentialId, rpId, options) ?: throw NoSuchElementException()
            PasskeyResponses.assertion(passkey, options.challenge, origin, clientDataHash)
        }) { result ->
            result.fold(
                onSuccess = { json ->
                    val data = Intent()
                    PendingIntentHandler.setGetCredentialResponse(data, GetCredentialResponse(PublicKeyCredential(json)))
                    setResult(Activity.RESULT_OK, data)
                    finish()
                },
                onFailure = { e ->
                    when (e) {
                        is KeyInvalidatedException -> invalidated()
                        is NoSuchElementException -> fail(NoCredentialException("Kemlock no longer holds this passkey"))
                        else -> showMessage(getString(R.string.passkeys_open_failed))
                    }
                },
            )
        }
    }

    /** The passkey, with its key, from the vault's copy or the provider's own records, if it is for [rpId] and allowed. */
    private fun find(vault: String, credentialId: String, rpId: String, options: RequestOptions): PasskeyEntry? {
        val id = B64.fromUrl(credentialId)
        if (options.allowed.isNotEmpty() && options.allowed.none { it.contentEquals(id) }) return null
        val held = AutofillStore(this).openPasskeys(vault) + PasskeyStore(this).openCreated(vault)
        return held.firstOrNull { it.privateKey != null && it.rpId == rpId && runCatching { B64.fromUrl(it.credentialId) }.getOrNull()?.contentEquals(id) == true }
    }

    /** Biometrics changed since the key was made: nothing sealed to it opens, so it all goes until the app writes it again. */
    private fun invalidated() {
        invalidated = true
        try {
            if (!AutofillKey.isValid()) AutofillStore(this).removeAll()
        } catch (_: Exception) {
            // Written again when the vault is next opened
        }
        showMessage(getString(R.string.passkeys_reopen))
    }

    private var invalidated = false

    /** Opened from the provider's "open Kemlock once" action rather than a passkey: closing goes back to the choice. */
    private var reopenOnly = false

    override fun cancelled() = when {
        reopenOnly -> finish()
        invalidated -> fail(NoCredentialException("Open Kemlock once to use its passkeys"))
        else -> fail(GetCredentialCancellationException("Cancelled"))
    }

    private fun fail(error: GetCredentialException) {
        val data = Intent()
        PendingIntentHandler.setGetCredentialException(data, error)
        setResult(Activity.RESULT_OK, data)
        finish()
    }

    companion object {
        private const val EXTRA_REOPEN = "com.kemlock.app.passkeys.REOPEN"

        fun intent(context: Context, vault: String, credentialId: String): Intent =
            Intent(context, PasskeyGetActivity::class.java).putExtra(EXTRA_VAULT, vault).putExtra(EXTRA_CREDENTIAL, credentialId)

        /** The screen that says to open Kemlock once, for when biometrics changed since the copies were written. */
        fun reopenIntent(context: Context): Intent = Intent(context, PasskeyGetActivity::class.java).putExtra(EXTRA_REOPEN, true)
    }
}
