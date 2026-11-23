package com.kemlock.app.passkeys

import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.TextView
import androidx.annotation.RequiresApi
import androidx.appcompat.app.AppCompatActivity
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import com.kemlock.app.ObscuredTouches
import com.kemlock.app.R
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * What a Kemlock passkey entry opens: a dialog over the app or site, kept out of screenshots and
 * the recent apps as the fill screen is (AutofillUnlockActivity, whose layout it shares), with the
 * biometric prompt and a message when something stops it. Biometrics alone count, never the
 * phone's passcode, and they unlock the autofill key for its few seconds.
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
abstract class PasskeyActivity : AppCompatActivity() {
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        setContentView(R.layout.autofill_unlock)
        ObscuredTouches.refuse(this)
        setResult(Activity.RESULT_CANCELED)
        findViewById<Button>(R.id.autofill_cancel).setOnClickListener { cancelled() }
    }

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }

    /** The person closed the screen or the prompt. */
    protected abstract fun cancelled()

    /**
     * Runs [work] off the main thread, since it may wait on the network or StrongBox, then hands
     * [then] what it gave or threw, on the main thread, while the screen is still up.
     */
    protected fun <T> background(work: () -> T, then: (Result<T>) -> Unit) {
        worker.execute {
            val result = runCatching(work)
            runOnUiThread { if (!isFinishing && !isDestroyed) then(result) }
        }
    }

    /** The biometric prompt, titled [title] for the site [rpId], then [onSuccess]. */
    protected fun prompt(title: String, rpId: String, onSuccess: () -> Unit) {
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(getString(R.string.autofill_prompt_for, rpId))
            .setNegativeButtonText(getString(R.string.autofill_cancel))
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .setConfirmationRequired(false)
            .build()
        BiometricPrompt(this, ContextCompat.getMainExecutor(this), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = onSuccess()

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                when (errorCode) {
                    BiometricPrompt.ERROR_NEGATIVE_BUTTON, BiometricPrompt.ERROR_USER_CANCELED, BiometricPrompt.ERROR_CANCELED -> cancelled()
                    else -> showMessage(errString.toString())
                }
            }
        }).authenticate(info)
    }

    protected fun showMessage(text: String) {
        findViewById<View>(R.id.autofill_picker).visibility = View.GONE
        findViewById<TextView>(R.id.autofill_message).apply {
            this.text = text
            visibility = View.VISIBLE
        }
        findViewById<Button>(R.id.autofill_cancel).setText(R.string.autofill_close)
    }

    companion object {
        const val EXTRA_VAULT = "com.kemlock.app.passkeys.VAULT"
        const val EXTRA_CREDENTIAL = "com.kemlock.app.passkeys.CREDENTIAL"
    }
}
