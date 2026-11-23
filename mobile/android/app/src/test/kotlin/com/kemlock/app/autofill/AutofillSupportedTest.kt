package com.kemlock.app.autofill

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * Codes and passwords are filled from Android 11 only, where the autofill key takes strong
 * biometrics alone (security audit 2026-11-21, M2). Read from the sources: the unit tests run in
 * the module's folder.
 */
class AutofillSupportedTest {
    private val setting = Regex("""<bool name="autofill_supported">(\w+)</bool>""")

    /** The value `autofill_supported` has in each resource folder that sets it. */
    private fun settings(): Map<String, String> = File("src/main/res").listFiles()!!
        .filter { it.isDirectory && it.name.startsWith("values") }
        .mapNotNull { dir ->
            dir.listFiles()!!.filter { it.extension == "xml" }
                .firstNotNullOfOrNull { setting.find(it.readText())?.groupValues?.get(1) }
                ?.let { dir.name to it }
        }
        .toMap()

    @Test
    fun theServiceAndItsScreenAreOnFromAndroid11Only() {
        assertEquals(mapOf("values" to "false", "values-v30" to "true"), settings())
        // The fill service, the fill screen and the strong-password sheet, all under it
        val manifest = File("src/main/AndroidManifest.xml").readText()
        val underIt = Regex("""android:name="([^"]+)"\s+android:enabled="@bool/autofill_supported"""").findAll(manifest).map { it.groupValues[1] }.toSet()
        assertEquals(setOf(".autofill.KemlockAutofillService", ".autofill.AutofillUnlockActivity", ".passwords.PasswordSuggestActivity"), underIt)
    }
}
