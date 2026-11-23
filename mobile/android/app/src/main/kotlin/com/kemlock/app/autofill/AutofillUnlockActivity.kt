package com.kemlock.app.autofill

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.service.autofill.Dataset
import android.text.Editable
import android.text.TextWatcher
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.autofill.AutofillId
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import android.widget.BaseAdapter
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.ListView
import android.widget.TextView
import androidx.annotation.RequiresApi
import androidx.appcompat.app.AppCompatActivity
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import com.kemlock.app.ObscuredTouches
import com.kemlock.app.R

/**
 * What a Kemlock suggestion opens: the biometric prompt, then the code typed in, or in its login
 * mode the username and password (openspec: add-passwords, design decision 10). A suggestion for
 * one account or login fills it at once, as does a site or app only one matches; otherwise the
 * screen lists them all, those that match first, with search, and can remember the pick for the
 * site or app. Nothing is shown before biometrics pass, and the screen is kept out of
 * screenshots and the recent apps, as the app is.
 */
@RequiresApi(Build.VERSION_CODES.O)
class AutofillUnlockActivity : AppCompatActivity() {
    private lateinit var store: AutofillStore
    private var forLogin = false
    private var fieldIds: List<AutofillId> = emptyList()
    private var characters = IntArray(0)
    private var usernameId: AutofillId? = null
    private var passwordId: AutofillId? = null
    private var target: Target? = null
    private var vault: String? = null
    private var chosenId: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        setContentView(R.layout.autofill_unlock)
        ObscuredTouches.refuse(this)
        setResult(Activity.RESULT_CANCELED)
        findViewById<Button>(R.id.autofill_cancel).setOnClickListener { finish() }

        store = AutofillStore(this)
        forLogin = intent.getStringExtra(EXTRA_MODE) == MODE_LOGIN
        if (forLogin) {
            @Suppress("DEPRECATION")
            usernameId = intent.getParcelableExtra(EXTRA_USERNAME)
            @Suppress("DEPRECATION")
            passwordId = intent.getParcelableExtra(EXTRA_PASSWORD)
        } else {
            @Suppress("DEPRECATION")
            fieldIds = intent.getParcelableArrayListExtra<AutofillId>(EXTRA_IDS).orEmpty()
            characters = intent.getIntArrayExtra(EXTRA_CHARACTERS) ?: IntArray(fieldIds.size) { -1 }
        }
        target = intent.getStringExtra(EXTRA_TARGET)?.let(Target::parse)
        vault = intent.getStringExtra(EXTRA_VAULT)
        chosenId = intent.getStringExtra(EXTRA_ACCOUNT)

        when {
            if (forLogin) usernameId == null && passwordId == null else fieldIds.isEmpty() -> finish()
            forLogin && !store.fillsLogins() -> showMessage(getString(R.string.autofill_no_logins))
            !forLogin && !store.hasCopies() -> showMessage(getString(R.string.autofill_no_codes))
            !AutofillKey.isValid() -> invalidated()
            savedInstanceState == null -> prompt()
            else -> finish()
        }
    }

    private fun prompt() {
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(getString(if (forLogin) R.string.autofill_prompt_login_title else R.string.autofill_prompt_title))
            .setSubtitle(getString(R.string.autofill_prompt_for, targetLabel()))
            .setNegativeButtonText(getString(R.string.autofill_cancel))
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .setConfirmationRequired(false)
            .build()
        BiometricPrompt(this, ContextCompat.getMainExecutor(this), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = open()

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                when (errorCode) {
                    BiometricPrompt.ERROR_NEGATIVE_BUTTON, BiometricPrompt.ERROR_USER_CANCELED, BiometricPrompt.ERROR_CANCELED -> finish()
                    else -> showMessage(errString.toString())
                }
            }
        }).authenticate(info)
    }

    private fun open() {
        val opened = try {
            store.open()
        } catch (_: KeyInvalidatedException) {
            return invalidated()
        } catch (_: Exception) {
            return showMessage(getString(if (forLogin) R.string.autofill_failed_logins else R.string.autofill_failed))
        }
        if (forLogin) openLogins(opened.logins, opened.picks) else openCodes(opened.accounts, opened.picks)
    }

    private fun openCodes(accounts: List<CopyAccount>, picks: List<Pick>) {
        val chosen = if (vault != null && chosenId != null) accounts.firstOrNull { it.vault == vault && it.id == chosenId } else null
        if (chosen != null) return fillCode(chosen, remember = false)
        val matches = Matching.matching(target, accounts, picks, { it.vault }, { it.id }, { it.domains })
        if (matches.size == 1) return fillCode(matches.single(), remember = false)
        val rows = (matches + accounts.filter { it !in matches }).map { account ->
            Row(account.name, account.label.takeIf { account.issuer.isNotEmpty() && it.isNotEmpty() }, "${account.issuer} ${account.label}") {
                fillCode(account, it)
            }
        }
        showList(
            rows,
            noMatch = matches.isEmpty(),
            search = R.string.autofill_search,
            remember = R.string.autofill_remember,
            any = R.string.autofill_choose_any,
            unknown = R.string.autofill_unknown,
            choose = R.string.autofill_choose,
        )
    }

    private fun openLogins(logins: List<LoginEntry>, picks: List<Pick>) {
        val chosen = if (vault != null && chosenId != null) logins.firstOrNull { it.vault == vault && it.id == chosenId } else null
        if (chosen != null) return fillLogin(chosen, remember = false)
        val matches = Matching.matching(target, logins, picks, { it.vault }, { it.id }, { it.domains })
        if (matches.size == 1) return fillLogin(matches.single(), remember = false)
        val rows = (matches + logins.filter { it !in matches }).map { login ->
            Row(login.name, login.username, listOfNotNull(login.name, login.username, *login.domains.toTypedArray()).joinToString(" ")) {
                fillLogin(login, it)
            }
        }
        showList(
            rows,
            noMatch = matches.isEmpty(),
            search = R.string.autofill_search_logins,
            remember = R.string.autofill_remember_login,
            any = R.string.autofill_choose_any_login,
            unknown = R.string.autofill_unknown_login,
            choose = R.string.autofill_choose_login,
        )
    }

    private fun showList(rows: List<Row>, noMatch: Boolean, search: Int, remember: Int, any: Int, unknown: Int, choose: Int) {
        findViewById<View>(R.id.autofill_picker).visibility = View.VISIBLE
        val message = findViewById<TextView>(R.id.autofill_message)
        message.text = when {
            target == null -> getString(any)
            noMatch -> getString(unknown, targetLabel())
            else -> getString(choose, targetLabel())
        }
        message.visibility = View.VISIBLE
        val box = findViewById<CheckBox>(R.id.autofill_remember)
        box.setText(remember)
        box.visibility = if (target != null && noMatch) View.VISIBLE else View.GONE
        val adapter = RowAdapter(this, rows)
        val list = findViewById<ListView>(R.id.autofill_list)
        list.adapter = adapter
        list.setOnItemClickListener { _, _, position, _ -> adapter.getItem(position).pick(box.isChecked) }
        findViewById<EditText>(R.id.autofill_search).apply {
            setHint(search)
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit

                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit

                override fun afterTextChanged(s: Editable?) = adapter.filter(s?.toString().orEmpty())
            })
        }
    }

    /** Remembers the pick of [id] in [vault] for the target, when asked; filling goes on if it can't. */
    private fun rememberPick(vault: String, id: String, remember: Boolean) {
        val target = target
        if (!remember || target == null) return
        try {
            store.remember(Pick(vault, target, id), login = forLogin)
        } catch (_: Exception) {
            // Filled all the same; the pick is offered again next time.
        }
    }

    private fun fillCode(chosen: CopyAccount, remember: Boolean) {
        rememberPick(chosen.vault, chosen.id, remember)
        val code = Otp.code(chosen, System.currentTimeMillis() / 1000)
        val presentation = KemlockAutofillService.presentation(this, chosen.name, getString(R.string.autofill_app_name))
        @Suppress("DEPRECATION")
        val dataset = Dataset.Builder(presentation)
        fieldIds.forEachIndexed { i, id ->
            val character = characters.getOrElse(i) { -1 }
            val value = if (character < 0) code else code.getOrNull(character)?.toString() ?: ""
            @Suppress("DEPRECATION")
            dataset.setValue(id, AutofillValue.forText(value), presentation)
        }
        finishWith(dataset.build())
    }

    /** Fills the username and the password the form has fields for; a login missing both leaves the form as it was. */
    private fun fillLogin(chosen: LoginEntry, remember: Boolean) {
        rememberPick(chosen.vault, chosen.id, remember)
        val values = listOfNotNull(
            usernameId?.let { id -> chosen.username?.let { id to it } },
            passwordId?.let { id -> chosen.password?.let { id to it } },
        )
        if (values.isEmpty()) return finish()
        val presentation = KemlockAutofillService.presentation(this, chosen.username ?: chosen.name, getString(R.string.autofill_app_name))
        @Suppress("DEPRECATION")
        val dataset = Dataset.Builder(presentation)
        for ((id, text) in values) {
            @Suppress("DEPRECATION")
            dataset.setValue(id, AutofillValue.forText(text), presentation)
        }
        finishWith(dataset.build())
    }

    private fun finishWith(dataset: Dataset) {
        setResult(Activity.RESULT_OK, Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, dataset))
        finish()
    }

    /** Biometrics changed since the key was made: nothing written before opens, so it all goes. */
    private fun invalidated() {
        store.removeAll()
        showMessage(getString(if (forLogin) R.string.autofill_reopen_logins else R.string.autofill_reopen))
    }

    private fun showMessage(text: String) {
        findViewById<View>(R.id.autofill_picker).visibility = View.GONE
        findViewById<TextView>(R.id.autofill_message).apply {
            this.text = text
            visibility = View.VISIBLE
        }
        findViewById<Button>(R.id.autofill_cancel).setText(R.string.autofill_close)
    }

    /** A website's host, or an app's name with its package, since any app can call itself github.com. */
    private fun targetLabel(): String = when (val t = target) {
        is Target.Web -> t.host
        is Target.App -> {
            val name = try {
                packageManager.getApplicationLabel(packageManager.getApplicationInfo(t.packageName, 0)).toString()
            } catch (_: Exception) {
                null
            }
            if (name.isNullOrBlank() || name == t.packageName) t.packageName else getString(R.string.autofill_app_label, name, t.packageName)
        }
        null -> getString(R.string.autofill_this_app)
    }

    /** One row of the list: an account or a login, the words search looks in, and what picking it does. */
    private class Row(val title: String, val subtitle: String?, words: String, val pick: (remember: Boolean) -> Unit) {
        val words = words.lowercase()
    }

    private class RowAdapter(context: Context, private val all: List<Row>) : BaseAdapter() {
        private val inflater = LayoutInflater.from(context)
        private var shown = all

        fun filter(query: String) {
            val q = query.trim().lowercase()
            shown = if (q.isEmpty()) all else all.filter { it.words.contains(q) }
            notifyDataSetChanged()
        }

        override fun getCount() = shown.size

        override fun getItem(position: Int) = shown[position]

        override fun getItemId(position: Int) = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val view = convertView ?: inflater.inflate(R.layout.autofill_account_row, parent, false)
            val item = shown[position]
            view.findViewById<TextView>(R.id.autofill_row_title).text = item.title
            view.findViewById<TextView>(R.id.autofill_row_subtitle).apply {
                text = item.subtitle.orEmpty()
                visibility = if (item.subtitle.isNullOrEmpty()) View.GONE else View.VISIBLE
            }
            return view
        }
    }

    companion object {
        private const val EXTRA_MODE = "com.kemlock.app.autofill.MODE"
        private const val EXTRA_IDS = "com.kemlock.app.autofill.IDS"
        private const val EXTRA_CHARACTERS = "com.kemlock.app.autofill.CHARACTERS"
        private const val EXTRA_USERNAME = "com.kemlock.app.autofill.USERNAME"
        private const val EXTRA_PASSWORD = "com.kemlock.app.autofill.PASSWORD"
        private const val EXTRA_TARGET = "com.kemlock.app.autofill.TARGET"
        private const val EXTRA_VAULT = "com.kemlock.app.autofill.VAULT"
        private const val EXTRA_ACCOUNT = "com.kemlock.app.autofill.ACCOUNT"
        private const val MODE_LOGIN = "login"

        fun intent(context: Context, fields: List<CodeField<AutofillId>>, target: Target?, vault: String?, account: String?): Intent =
            Intent(context, AutofillUnlockActivity::class.java)
                .putParcelableArrayListExtra(EXTRA_IDS, ArrayList(fields.map { it.id }))
                .putExtra(EXTRA_CHARACTERS, fields.map { it.character ?: -1 }.toIntArray())
                .putExtra(EXTRA_TARGET, target?.toString())
                .putExtra(EXTRA_VAULT, vault)
                .putExtra(EXTRA_ACCOUNT, account)

        /** Fills [login] of [vault] into the form's [username] and [password] fields; with no login, the list. */
        fun loginIntent(context: Context, username: AutofillId?, password: AutofillId?, target: Target?, vault: String?, login: String?): Intent =
            Intent(context, AutofillUnlockActivity::class.java)
                .putExtra(EXTRA_MODE, MODE_LOGIN)
                .putExtra(EXTRA_USERNAME, username)
                .putExtra(EXTRA_PASSWORD, password)
                .putExtra(EXTRA_TARGET, target?.toString())
                .putExtra(EXTRA_VAULT, vault)
                .putExtra(EXTRA_ACCOUNT, login)
    }
}
