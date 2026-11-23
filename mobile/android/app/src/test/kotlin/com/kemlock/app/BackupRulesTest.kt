package com.kemlock.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * A backup takes the vault's storage alone, and a cloud backup only when it is end-to-end
 * encrypted (security audit 2026-11-21, I6). Read from the sources: the unit tests run in the
 * module's folder.
 */
class BackupRulesTest {
    private val include = Regex("""<include\s+domain="(\w+)"\s+path="([^"]+)"(?:\s+requireFlags="(\w+)")?\s*/>""")

    private fun includes(file: String): List<Triple<String, String, String?>> =
        include.findAll(File(file).readText()).map { Triple(it.groupValues[1], it.groupValues[2], it.groupValues[3].ifEmpty { null }) }.toList()

    @Test
    fun theManifestNamesBothRuleFiles() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        assertTrue(manifest.contains("""android:dataExtractionRules="@xml/data_extraction_rules""""))
        assertTrue(manifest.contains("""android:fullBackupContent="@xml/backup_rules""""))
    }

    @Test
    fun android12AndLaterTakeTheVaultAloneAndOnlyToAnEncryptedCloudBackup() {
        val rules = File("src/main/res/xml/data_extraction_rules.xml").readText()
        assertTrue(rules.contains("""<cloud-backup disableIfNoEncryptionCapabilities="true">"""))
        assertEquals(List(2) { Triple("sharedpref", "CapacitorStorage.xml", null) }, includes("src/main/res/xml/data_extraction_rules.xml"))
        assertTrue(!rules.contains("<exclude"))
    }

    @Test
    fun android11AndEarlierTakeTheVaultAloneToAnEncryptedBackupOrANewPhone() {
        assertEquals(
            listOf(
                Triple("sharedpref", "CapacitorStorage.xml", "clientSideEncryption"),
                Triple("sharedpref", "CapacitorStorage.xml", "deviceToDeviceTransfer"),
            ),
            includes("src/main/res/xml/backup_rules.xml"),
        )
    }
}
