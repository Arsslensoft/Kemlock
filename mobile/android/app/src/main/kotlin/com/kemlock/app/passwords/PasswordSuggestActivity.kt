package com.kemlock.app.passwords

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.service.autofill.Dataset
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.view.View
import android.view.WindowManager
import android.view.autofill.AutofillId
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import android.widget.Button
import android.widget.CheckBox
import android.widget.SeekBar
import android.widget.TextView
import androidx.annotation.RequiresApi
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.kemlock.app.ObscuredTouches
import com.kemlock.app.R
import com.kemlock.app.autofill.KemlockAutofillService
import com.kemlock.app.passkeys.PasskeyStore

/**
 * The sheet "Suggest a strong password" opens on a sign-up or change-password form (openspec:
 * add-passwords, the password-autofill spec): a password made on the phone that follows the
 * site's rules and the field's maximum length, Again, the generator's choices, and "Fill
 * password", which fills it into the new password and its confirmation. It needs no biometrics:
 * it opens nothing of the vault. Filling seals the password to the vault that saves logins, so it
 * is kept under Recently generated even if no save follows. Kept out of screenshots and the
 * recent apps, as the fill screen is.
 */
@RequiresApi(Build.VERSION_CODES.O)
class PasswordSuggestActivity : AppCompatActivity() {
    private val source = SecureByteSource()
    private lateinit var ids: List<AutofillId>
    private var site: String? = null
    private var rules: PasswordRules? = null
    private var vault: String? = null
    private var choices = PasswordChoices()
    private var password = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        setContentView(R.layout.password_suggest)
        ObscuredTouches.refuse(this)
        setResult(Activity.RESULT_CANCELED)
        @Suppress("DEPRECATION")
        ids = intent.getParcelableArrayListExtra<AutofillId>(EXTRA_IDS).orEmpty()
        if (ids.isEmpty()) return finish()
        site = intent.getStringExtra(EXTRA_SITE)
        vault = intent.getStringExtra(EXTRA_VAULT)
        rules = rulesWithMaxLength(intent.getStringExtra(EXTRA_RULES), intent.getIntExtra(EXTRA_MAX_LENGTH, -1))
        choices = loadChoices(this)

        val label = intent.getStringExtra(EXTRA_LABEL) ?: getString(R.string.autofill_this_app)
        findViewById<TextView>(R.id.password_suggest_for).text = getString(R.string.password_suggest_for, label)
        if (intent.getStringExtra(EXTRA_RULES) != null) {
            findViewById<TextView>(R.id.password_suggest_rules).apply {
                text = getString(R.string.password_suggest_rules, label)
                visibility = View.VISIBLE
            }
        }
        val vaultName = intent.getStringExtra(EXTRA_VAULT_NAME)
        findViewById<TextView>(R.id.password_suggest_note).text =
            if (vault != null && vaultName != null) getString(R.string.password_suggest_kept, vaultName) else getString(R.string.password_suggest_not_kept)

        bindChoices()
        findViewById<Button>(R.id.password_suggest_again).setOnClickListener { make() }
        findViewById<Button>(R.id.password_suggest_cancel).setOnClickListener { finish() }
        findViewById<Button>(R.id.password_suggest_fill).setOnClickListener { fill() }
        make()
    }

    private fun bindChoices() {
        val length = findViewById<TextView>(R.id.password_suggest_length)
        val bar = findViewById<SeekBar>(R.id.password_suggest_length_bar)
        bar.min = MIN_PASSWORD_LENGTH
        bar.max = MAX_PASSWORD_LENGTH
        bar.progress = choices.length
        length.text = getString(R.string.password_suggest_length, choices.length)
        bar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                if (!fromUser) return
                choices = choices.copy(length = progress)
                length.text = getString(R.string.password_suggest_length, progress)
                make()
            }

            override fun onStartTrackingTouch(seekBar: SeekBar?) = Unit

            override fun onStopTrackingTouch(seekBar: SeekBar?) = Unit
        })
        fun box(id: Int, value: Boolean, change: (Boolean) -> PasswordChoices) = findViewById<CheckBox>(id).apply {
            isChecked = value
            setOnCheckedChangeListener { _, on ->
                choices = change(on)
                make()
            }
        }
        box(R.id.password_suggest_capitals, choices.capitals) { choices.copy(capitals = it) }
        box(R.id.password_suggest_digits, choices.digits) { choices.copy(digits = it) }
        box(R.id.password_suggest_symbols, choices.symbols) { choices.copy(symbols = it) }
        box(R.id.password_suggest_look_alikes, choices.avoidLookAlikes) { choices.copy(avoidLookAlikes = it) }
    }

    /** A new password with the choices now, its digits and symbols coloured as the app colours them. */
    private fun make() {
        password = generatePassword(source, choices, rules)
        val shown = SpannableString(password)
        val digit = ContextCompat.getColor(this, R.color.autofill_accent)
        password.forEachIndexed { i, c ->
            val colour = when {
                c.isDigit() -> digit
                c.isLetter() || c == ' ' -> null
                else -> SYMBOL_COLOUR
            }
            if (colour != null) shown.setSpan(ForegroundColorSpan(colour), i, i + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        findViewById<TextView>(R.id.password_suggest_value).apply {
            text = shown
            contentDescription = password.toList().joinToString(" ")
        }
    }

    private fun fill() {
        saveChoices(this, choices)
        // Kept for the vault even if no save follows; filling goes on if it can't be
        vault?.let { vault ->
            try {
                PasskeyStore(this).saveLogin(vault, LoginRecord.Generated(password, site, System.currentTimeMillis()))
            } catch (_: Exception) {
                // The password is filled all the same, and the save prompt still offers to keep it.
            }
        }
        // A login saved with it is marked as generated
        GeneratedPasswords.remember(this, password)
        val presentation = KemlockAutofillService.presentation(this, getString(R.string.password_suggest), getString(R.string.autofill_app_name))
        @Suppress("DEPRECATION")
        val dataset = Dataset.Builder(presentation)
        for (id in ids) {
            @Suppress("DEPRECATION")
            dataset.setValue(id, AutofillValue.forText(password), presentation)
        }
        setResult(Activity.RESULT_OK, Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, dataset.build()))
        finish()
    }

    companion object {
        private const val EXTRA_IDS = "com.kemlock.app.passwords.IDS"
        private const val EXTRA_SITE = "com.kemlock.app.passwords.SITE"
        private const val EXTRA_LABEL = "com.kemlock.app.passwords.LABEL"
        private const val EXTRA_RULES = "com.kemlock.app.passwords.RULES"
        private const val EXTRA_MAX_LENGTH = "com.kemlock.app.passwords.MAX_LENGTH"
        private const val EXTRA_VAULT = "com.kemlock.app.passwords.VAULT"
        private const val EXTRA_VAULT_NAME = "com.kemlock.app.passwords.VAULT_NAME"
        private const val PREFERENCES = "kemlock_password_generator"
        private const val SYMBOL_COLOUR = 0xFFC2410C.toInt()

        /**
         * Opens the sheet for the new password [ids] of [site] (null in an app), named [label],
         * with the site's [rules] when known and the field's [maxLength] when it has one; the
         * password is kept for [vault], named [vaultName], when a vault saves logins.
         */
        fun intent(
            context: Context,
            ids: List<AutofillId>,
            site: String?,
            label: String,
            rules: String?,
            maxLength: Int?,
            vault: String?,
            vaultName: String?,
        ): Intent = Intent(context, PasswordSuggestActivity::class.java)
            .putParcelableArrayListExtra(EXTRA_IDS, ArrayList(ids))
            .putExtra(EXTRA_SITE, site)
            .putExtra(EXTRA_LABEL, label)
            .putExtra(EXTRA_RULES, rules)
            .putExtra(EXTRA_MAX_LENGTH, maxLength ?: -1)
            .putExtra(EXTRA_VAULT, vault)
            .putExtra(EXTRA_VAULT_NAME, vaultName)

        private fun loadChoices(context: Context): PasswordChoices {
            val prefs = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            val defaults = PasswordChoices()
            return PasswordChoices(
                length = prefs.getInt("length", defaults.length).coerceIn(MIN_PASSWORD_LENGTH, MAX_PASSWORD_LENGTH),
                capitals = prefs.getBoolean("capitals", defaults.capitals),
                digits = prefs.getBoolean("digits", defaults.digits),
                symbols = prefs.getBoolean("symbols", defaults.symbols),
                avoidLookAlikes = prefs.getBoolean("avoidLookAlikes", defaults.avoidLookAlikes),
            )
        }

        private fun saveChoices(context: Context, choices: PasswordChoices) {
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
                .putInt("length", choices.length)
                .putBoolean("capitals", choices.capitals)
                .putBoolean("digits", choices.digits)
                .putBoolean("symbols", choices.symbols)
                .putBoolean("avoidLookAlikes", choices.avoidLookAlikes)
                .apply()
        }
    }
}
