package com.kemlock.app.autofill

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.app.assist.AssistStructure
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.BatchUpdates
import android.service.autofill.CharSequenceTransformation
import android.service.autofill.CustomDescription
import android.service.autofill.Dataset
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.InlinePresentation
import android.service.autofill.RegexValidator
import android.service.autofill.SaveCallback
import android.service.autofill.SaveInfo
import android.service.autofill.SaveRequest
import android.view.View
import android.view.autofill.AutofillId
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
import androidx.autofill.inline.UiVersions
import androidx.autofill.inline.v1.InlineSuggestionUi
import com.kemlock.app.R
import com.kemlock.app.passkeys.BundledBrowsers
import com.kemlock.app.passkeys.Caller
import com.kemlock.app.passkeys.PasskeyStore
import com.kemlock.app.passwords.GeneratedPasswords
import com.kemlock.app.passwords.PasswordSuggestActivity
import com.kemlock.app.passwords.SaveDecision
import com.kemlock.app.passwords.SaveFields
import com.kemlock.app.passwords.SavingVaults
import com.kemlock.app.passwords.SiteRules
import java.security.MessageDigest
import java.util.UUID
import java.util.regex.Pattern

/**
 * Kemlock's autofill service (openspec: add-passwords, the code-autofill and password-autofill
 * specs): on a one-time code field of another app or website, or any field the person asks to
 * autofill from its menu, it suggests the matching accounts, by name when the vault keeps an
 * index, and one "Fill a code" suggestion; on a login form's username or password, the matching
 * logins by name and one "Another login". A website counts only in a browser on the list of
 * trusted browsers, and only over https ([Matching.target]): a page of anything else gets no
 * code or login by name, no remembered pick and no offer to save. Every suggestion opens
 * [AutofillUnlockActivity], which asks for biometrics before any code or password is filled.
 */
@RequiresApi(Build.VERSION_CODES.O)
class KemlockAutofillService : AutofillService() {
    override fun onFillRequest(request: FillRequest, cancellationSignal: CancellationSignal, callback: FillCallback) {
        val response = try {
            respond(request)
        } catch (_: Exception) {
            null
        }
        callback.onSuccess(response)
    }

    /**
     * Keeps the login a sent form holds (openspec: add-passwords, the password-autofill spec), in
     * the vault the prompt named: sealed to its inbox key, for the app to take in when the vault is
     * next opened. It opens nothing, so it needs no biometrics; a login saved in an app is picked
     * for it there, so it is suggested by name next time.
     */
    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        try {
            save(request)
        } catch (_: Exception) {
            // Nothing to keep, or the inbox can't be written: the prompt goes, and the form is as it was
        }
        callback.onSuccess()
    }

    private fun save(request: SaveRequest) {
        val state = request.clientState ?: return
        val target = state.getString(STATE_TARGET)?.let(Target::parse) ?: return
        val vault = state.getString(STATE_VAULT) ?: return
        @Suppress("DEPRECATION")
        val fields = SaveFields<AutofillId>(
            state.getParcelable(STATE_USERNAME),
            state.getParcelable(STATE_PASSWORD),
            state.getParcelableArrayList<AutofillId>(STATE_NEW_PASSWORDS).orEmpty(),
        )
        // Every screen of the form, oldest first, so the values typed last count
        val roots = request.fillContexts.flatMap { context ->
            (0 until context.structure.windowNodeCount).map { ViewNodeField(context.structure.getWindowNodeAt(it).rootViewNode) }
        }
        val store = AutofillStore(this)
        val (_, picks) = store.suggestions()
        val result = SaveDecision.decide(
            roots,
            fields,
            target,
            vault,
            store.indexLogins(),
            picks,
            appLabel(this, target),
            System.currentTimeMillis(),
            { GeneratedPasswords.wasGenerated(this, it) },
            { UUID.randomUUID().toString() },
        ) ?: return
        PasskeyStore(this).saveLogin(vault, result.record)
        if (target is Target.App && !result.update) {
            try {
                store.remember(Pick(vault, target, result.record.id), login = true)
            } catch (_: Exception) {
                // Saved all the same; the person picks it in the app once
            }
        }
    }

    private fun respond(request: FillRequest): FillResponse? {
        val structure = request.fillContexts.lastOrNull()?.structure ?: return null
        val packageName = structure.activityComponent.packageName
        if (packageName == this.packageName) return null
        val store = AutofillStore(this)
        // A vault whose copy holds passkeys alone has neither a code nor a login to offer
        val codes = store.fillsCodes()
        val logins = store.fillsLogins()
        if (!codes && !logins) return null
        val roots = (0 until structure.windowNodeCount).map { ViewNodeField(structure.getWindowNodeAt(it).rootViewNode) }
        // Asked for from a field's menu: that field is filled even when nothing says it wants a code
        val manual = request.flags and FillRequest.FLAG_MANUAL_REQUEST != 0
        val login = if (logins) FieldFinder.findLogin(roots) else null
        val found = if (codes) FieldFinder.find(roots, manual) else FoundFields(emptyList(), null)
        // The field the person is in decides; with none, a code field before a login form
        if (login != null && !login.isEmpty && (login.focused != null || found.fields.isEmpty())) {
            return loginResponse(request, store, login, packageName)
        }
        if (found.fields.isEmpty()) return null

        // A website only from a trusted browser; any other app is matched as itself, whatever site it names
        val target = Matching.target(found.webDomain, found.webScheme, signers(this, packageName), BundledBrowsers.get(this))
        val (index, picks) = store.suggestions()
        val matches = Matching.matching(target, index, picks, { it.vault }, { it.id }, { it.domains })

        // The keyboard's strip holds so many suggestions; one is kept for picking any account.
        val limit = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) inlineLimit(request) else MAX_SUGGESTIONS + 1
        val response = FillResponse.Builder()
        val shown = matches.take(minOf(MAX_SUGGESTIONS, limit - 1).coerceAtLeast(0))
        shown.forEachIndexed { i, account -> response.addDataset(dataset(request, found, target, account, i)) }
        // Always one more, to pick any account once biometrics pass.
        response.addDataset(dataset(request, found, target, null, shown.size))
        return response.build()
    }

    /**
     * A login form's suggestions: each login that matches the site or app, by name, and one more
     * for any login once biometrics pass; on a sign-up or change-password form, with suggesting
     * on, "Suggest a strong password" too, first when the new password is the focused field. A
     * sign-up form, with no current password to fill, gets no login.
     */
    private fun loginResponse(request: FillRequest, store: AutofillStore, login: LoginFields<AutofillId>, packageName: String): FillResponse? {
        val signsIn = login.password != null || (login.username != null && !login.asksNewPassword)
        val suggests = login.asksNewPassword && store.vaults().any(store::suggestsPasswords)
        // As for codes: a site not loaded over https is no target, so no login by name, no pick and no save
        val target = Matching.target(login.webDomain, login.webScheme, signers(this, packageName), BundledBrowsers.get(this))
        // The vault a sent form's login goes into, while one saves logins: the one opened last
        val saving = if (target != null && (login.password != null || login.asksNewPassword)) SavingVaults.ordered(this).firstOrNull() else null
        if (!signsIn && !suggests && saving == null) return null
        val limit = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) inlineLimit(request) else MAX_SUGGESTIONS + 1
        val response = FillResponse.Builder()
        var position = 0
        val suggestFirst = suggests && (login.focused == LoginRole.NEW_PASSWORD || !signsIn)
        if (suggestFirst) response.addDataset(suggestDataset(request, login, target, position++))
        if (signsIn) {
            val (_, picks) = store.suggestions()
            val matches = Matching.matching(target, store.indexLogins(), picks, { it.vault }, { it.id }, { it.domains })
            val room = limit - position - 1 - (if (suggests && !suggestFirst) 1 else 0)
            val shown = matches.take(minOf(MAX_SUGGESTIONS, room).coerceAtLeast(0))
            shown.forEach { entry -> response.addDataset(loginDataset(request, login, target, entry, position++)) }
            // Always one more, to pick any login once biometrics pass.
            response.addDataset(loginDataset(request, login, target, null, position++))
        }
        if (suggests && !suggestFirst) response.addDataset(suggestDataset(request, login, target, position))
        if (saving != null && target != null) {
            response.setSaveInfo(saveInfo(login, target, saving, store))
            response.setClientState(
                Bundle().apply {
                    putString(STATE_TARGET, target.toString())
                    putString(STATE_VAULT, saving)
                    putParcelable(STATE_USERNAME, login.username)
                    putParcelable(STATE_PASSWORD, login.password)
                    putParcelableArrayList(STATE_NEW_PASSWORDS, ArrayList(login.newPasswords))
                },
            )
        }
        return response.build()
    }

    /**
     * Asks Android to offer saving once the form is sent: the new password, else the current one,
     * required, the username and the rest optional, saved when the form's fields go away. The
     * prompt names the site or app, the username typed and the vault, and reads "Update in
     * Kemlock?" when the vault holds a login for that site and username.
     */
    private fun saveInfo(login: LoginFields<AutofillId>, target: Target, vault: String, store: AutofillStore): SaveInfo {
        val required = login.newPasswords.firstOrNull() ?: login.password!!
        val optional = (listOfNotNull(login.username, login.password) + login.newPasswords).filter { it != required }
        val type = SaveInfo.SAVE_DATA_TYPE_PASSWORD or (if (login.username != null) SaveInfo.SAVE_DATA_TYPE_USERNAME else 0)
        val where = (target as? Target.Web)?.host ?: appLabel(this, target)
        val vaultName = SavingVaults.name(this, vault)
        val builder = SaveInfo.Builder(type, arrayOf(required))
            .setFlags(SaveInfo.FLAG_SAVE_ON_ALL_VIEWS_INVISIBLE)
            .setDescription(getString(R.string.password_save_description, where, vaultName))
        if (optional.isNotEmpty()) builder.setOptionalIds(optional.toTypedArray())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val (_, picks) = store.suggestions()
            val known = SaveDecision.knownUsernames(target, vault, store.indexLogins(), picks)
            builder.setCustomDescription(saveDescription(login.username, where, vaultName, known))
        }
        return builder.build()
    }

    @RequiresApi(Build.VERSION_CODES.P)
    private fun saveDescription(username: AutofillId?, where: String, vaultName: String, known: List<String>): CustomDescription {
        fun views(title: Int) = RemoteViews(packageName, R.layout.autofill_save).apply {
            setTextViewText(R.id.autofill_save_title, getString(title))
            setTextViewText(R.id.autofill_save_site, where)
            setTextViewText(R.id.autofill_save_vault, getString(R.string.password_save_vault, vaultName))
        }
        val builder = CustomDescription.Builder(views(R.string.password_save_title))
        if (username != null) {
            // The username as typed, whatever it is
            builder.addChild(R.id.autofill_save_username, CharSequenceTransformation.Builder(username, Pattern.compile("^(.*)$"), "$1").build())
            if (known.isNotEmpty()) {
                // A username the vault holds a login for, whatever its case: the password is an update
                val pattern = Pattern.compile("^\\s*(?:" + known.joinToString("|") { Pattern.quote(it) } + ")\\s*$", Pattern.CASE_INSENSITIVE)
                val update = RemoteViews(packageName, R.layout.autofill_save).apply { setTextViewText(R.id.autofill_save_title, getString(R.string.password_update_title)) }
                builder.batchUpdate(RegexValidator(username, pattern), BatchUpdates.Builder().updateTemplate(update).build())
            }
        }
        return builder.build()
    }

    /**
     * "Suggest a strong password": opens [PasswordSuggestActivity], with no biometrics, to fill a
     * password made for the site's rules into the new password and its confirmation.
     */
    private fun suggestDataset(request: FillRequest, login: LoginFields<AutofillId>, target: Target?, position: Int): Dataset {
        val title = getString(R.string.password_suggest)
        val presentation = presentation(this, title, getString(R.string.autofill_app_name))
        val site = (target as? Target.Web)?.host
        val rules = login.newPasswordRules ?: site?.let { SiteRules.bundled(this).textFor(it) }
        val vault = SavingVaults.ordered(this).firstOrNull()
        val sheet = PasswordSuggestActivity.intent(
            this,
            login.newPasswords,
            site,
            label = site ?: appLabel(this, target),
            rules = rules,
            maxLength = login.newPasswordMaxLength,
            vault = vault,
            vaultName = vault?.let { SavingVaults.name(this, it) },
        )
        val sender = PendingIntent.getActivity(this, nextRequestCode(), sheet, PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE).intentSender
        @Suppress("DEPRECATION")
        val builder = Dataset.Builder(presentation)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            inlinePresentation(request, title, position)?.let {
                @Suppress("DEPRECATION")
                builder.setInlinePresentation(it)
            }
        }
        for (id in login.newPasswords) {
            @Suppress("DEPRECATION")
            builder.setValue(id, null, presentation)
        }
        builder.setAuthentication(sender)
        return builder.build()
    }

    private fun loginDataset(request: FillRequest, login: LoginFields<AutofillId>, target: Target?, entry: LoginEntry?, position: Int): Dataset {
        // Named by its username with the login's name: "ada@example.org", "Larkspur Mail"
        val title = entry?.let { it.username ?: it.name } ?: getString(R.string.autofill_another_login)
        val subtitle = entry?.takeIf { it.username != null }?.name ?: getString(R.string.autofill_app_name)
        val presentation = presentation(this, title, subtitle)
        val unlock = AutofillUnlockActivity.loginIntent(this, login.username, login.password, target, entry?.vault, entry?.id)
        val sender = PendingIntent.getActivity(this, nextRequestCode(), unlock, PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE).intentSender
        @Suppress("DEPRECATION")
        val builder = Dataset.Builder(presentation)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            inlinePresentation(request, title, position, subtitle)?.let {
                @Suppress("DEPRECATION")
                builder.setInlinePresentation(it)
            }
        }
        for (id in listOfNotNull(login.username, login.password)) {
            @Suppress("DEPRECATION")
            builder.setValue(id, null, presentation)
        }
        builder.setAuthentication(sender)
        return builder.build()
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun inlineLimit(request: FillRequest): Int = request.inlineSuggestionsRequest?.maxSuggestionCount?.coerceAtLeast(1) ?: (MAX_SUGGESTIONS + 1)

    private fun dataset(request: FillRequest, found: FoundFields<AutofillId>, target: Target?, account: IndexAccount?, position: Int): Dataset {
        val title = account?.issuer?.ifEmpty { null } ?: getString(R.string.autofill_fill_code)
        val presentation = presentation(this, title, getString(R.string.autofill_app_name))
        val unlock = AutofillUnlockActivity.intent(this, found.fields, target, account?.vault, account?.id)
        val sender = PendingIntent.getActivity(this, nextRequestCode(), unlock, PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE).intentSender
        @Suppress("DEPRECATION")
        val builder = Dataset.Builder(presentation)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            inlinePresentation(request, title, position)?.let {
                @Suppress("DEPRECATION")
                builder.setInlinePresentation(it)
            }
        }
        for (field in found.fields) {
            @Suppress("DEPRECATION")
            builder.setValue(field.id, null, presentation)
        }
        builder.setAuthentication(sender)
        return builder.build()
    }

    /** The suggestion in the keyboard's strip, styled by the keyboard's spec for its [position]. */
    // getSlice() is how androidx.autofill's own docs and samples hand the content over; its lint is too strict.
    @SuppressLint("RestrictedApi")
    @RequiresApi(Build.VERSION_CODES.R)
    private fun inlinePresentation(request: FillRequest, title: String, position: Int, subtitle: String = getString(R.string.autofill_app_name)): InlinePresentation? {
        val specs = request.inlineSuggestionsRequest?.inlinePresentationSpecs
        if (specs.isNullOrEmpty()) return null
        val spec = specs[minOf(position, specs.size - 1)]
        if (!UiVersions.getVersions(spec.style).contains(UiVersions.INLINE_UI_VERSION_1)) return null
        val attribution = PendingIntent.getActivity(this, 0, Intent(), PendingIntent.FLAG_IMMUTABLE)
        val slice = InlineSuggestionUi.newContentBuilder(attribution)
            .setTitle(title)
            .setSubtitle(subtitle)
            .setStartIcon(Icon.createWithResource(this, R.mipmap.ic_launcher))
            .setContentDescription(getString(R.string.autofill_suggestion_description, title))
            .build()
            .slice
        return InlinePresentation(slice, spec, false)
    }

    companion object {
        private const val MAX_SUGGESTIONS = 4
        private const val STATE_TARGET = "com.kemlock.app.autofill.TARGET"
        private const val STATE_VAULT = "com.kemlock.app.autofill.VAULT"
        private const val STATE_USERNAME = "com.kemlock.app.autofill.USERNAME"
        private const val STATE_PASSWORD = "com.kemlock.app.autofill.PASSWORD"
        private const val STATE_NEW_PASSWORDS = "com.kemlock.app.autofill.NEW_PASSWORDS"
        private var requestCode = 0

        @Synchronized
        private fun nextRequestCode(): Int = ++requestCode

        /** An app's name, else its package, for a sheet that says what it fills; "this app" when there is none. */
        fun appLabel(context: Context, target: Target?): String {
            val app = target as? Target.App ?: return context.getString(R.string.autofill_this_app)
            val pm = context.packageManager
            return try {
                pm.getApplicationLabel(pm.getApplicationInfo(app.packageName, 0)).toString().ifBlank { app.packageName }
            } catch (_: PackageManager.NameNotFoundException) {
                app.packageName
            }
        }

        fun presentation(context: Context, title: String, subtitle: String): RemoteViews =
            RemoteViews(context.packageName, R.layout.autofill_suggestion).apply {
                setTextViewText(R.id.autofill_title, title)
                setTextViewText(R.id.autofill_subtitle, subtitle)
            }

        /**
         * The SHA-256 of each certificate the app is signed with, as the passkey provider reads a
         * caller's, or null when they can't be read: its signers now and, with one signer, the
         * rotation lineage, the original first, so a pick survives a rotation.
         */
        fun signers(context: Context, packageName: String): Caller? = try {
            val pm = context.packageManager
            fun digest(signature: Signature) = MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
            val caller = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES).signingInfo?.let { info ->
                    val multiple = info.hasMultipleSigners()
                    val lineage = if (multiple) emptyList() else info.signingCertificateHistory.orEmpty().map(::digest)
                    Caller(packageName, info.apkContentsSigners.orEmpty().map(::digest), lineage, multiple, forWebsite = false, origin = null)
                }
            } else {
                @Suppress("DEPRECATION")
                val signers = pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES).signatures.orEmpty().map(::digest)
                Caller(packageName, signers, if (signers.size > 1) emptyList() else signers, signers.size > 1, forWebsite = false, origin = null)
            }
            caller?.takeIf { it.signers.isNotEmpty() }
        } catch (_: PackageManager.NameNotFoundException) {
            null
        }
    }
}

/** A view of the structure being filled, as [FieldFinder] reads it. */
@RequiresApi(Build.VERSION_CODES.O)
private class ViewNodeField(private val node: AssistStructure.ViewNode) : FieldNode<AutofillId> {
    override val id: AutofillId? get() = node.autofillId
    override val autofillHints: List<String> get() = node.autofillHints?.toList().orEmpty()
    override val htmlTag: String? get() = node.htmlInfo?.tag
    override val htmlAttributes: Map<String, String>
        get() = node.htmlInfo?.attributes?.associate { (it.first ?: "").lowercase() to (it.second ?: "") }.orEmpty()
    override val idEntry: String? get() = node.idEntry
    override val hint: String? get() = node.hint
    override val contentDescription: String? get() = node.contentDescription?.toString()
    override val inputType: Int get() = node.inputType
    override val maxLength: Int get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) node.maxTextLength else -1
    override val visible: Boolean get() = node.visibility == View.VISIBLE
    override val isText: Boolean get() = node.autofillType == View.AUTOFILL_TYPE_TEXT
    override val focused: Boolean get() = node.isFocused
    override val webDomain: String? get() = node.webDomain
    override val webScheme: String? get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) node.webScheme else null
    override val children: List<FieldNode<AutofillId>> get() = (0 until node.childCount).map { ViewNodeField(node.getChildAt(it)) }
    override val value: String? get() = node.autofillValue?.takeIf { it.isText }?.textValue?.toString()
}
