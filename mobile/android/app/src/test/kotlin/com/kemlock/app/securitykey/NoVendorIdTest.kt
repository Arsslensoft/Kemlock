package com.kemlock.app.securitykey

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * A security key is recognised by the interfaces it declares and by nothing that names its
 * maker or model (openspec: add-security-key-management, design decision 5). This reads the
 * sources and the manifest and fails when a brand table could have crept in.
 */
class NoVendorIdTest {
    /**
     * The app module's `src/main`. Gradle runs unit tests in the module's directory; an IDE may
     * run them from `android/`, `mobile/` or the repository's root.
     */
    private val main: File = generateSequence(File("").absoluteFile) { it.parentFile }
        .flatMap { sequenceOf(it, File(it, "app"), File(it, "android/app"), File(it, "mobile/android/app")) }
        .map { File(it, "src/main") }
        .first { File(it, "AndroidManifest.xml").isFile && File(it, SOURCES).isDirectory }

    private val forbidden = listOf("vendorId", "getVendorId", "productId", "getProductId", "vendor-id", "product-id", "device_filter")

    @Test
    fun noSourceNamesAMakerOrAModel() {
        val sources = File(main, SOURCES).walkTopDown().filter { it.isFile }.toList()

        assertEquals(
            setOf("NfcLink.kt", "SecurityKeyChannel.kt", "UsbDescriptors.kt", "UsbLinks.kt"),
            sources.map { it.name }.toSet(),
        )
        for (source in sources) {
            val text = source.readText()
            for (word in forbidden) assertFalse("${source.name} contains $word", text.contains(word, ignoreCase = true))
            // The serial number is never read either
            assertFalse("${source.name} reads the serial number", text.contains("serialNumber", ignoreCase = true))
        }
    }

    @Test
    fun theManifestHasNoDeviceFilter() {
        val manifest = File(main, "AndroidManifest.xml").readText()

        for (word in forbidden + "USB_DEVICE_ATTACHED") assertFalse("The manifest contains $word", manifest.contains(word, ignoreCase = true))
        // What it does declare: NFC, and both kinds of hardware as optional
        assertTrue(manifest.contains("<uses-permission android:name=\"android.permission.NFC\" />"))
        assertTrue(manifest.contains("<uses-feature android:name=\"android.hardware.nfc\" android:required=\"false\" />"))
        assertTrue(manifest.contains("<uses-feature android:name=\"android.hardware.usb.host\" android:required=\"false\" />"))
    }

    private companion object {
        const val SOURCES = "kotlin/com/kemlock/app/securitykey"
    }
}
