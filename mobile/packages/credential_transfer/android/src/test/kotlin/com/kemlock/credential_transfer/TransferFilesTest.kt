package com.kemlock.credential_transfer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/** The transfer's plain copy in the cache is deleted, and nothing else in it (task 5.3). */
class TransferFilesTest {
    @get:Rule
    val cache = TemporaryFolder()

    private fun put(path: String): File = File(cache.root, path).also {
        it.parentFile!!.mkdirs()
        it.writeText("secret")
    }

    @Test
    fun deletesTheLibrarysFolderWithWhatItHolds() {
        val file = put("import_export_temp/transfer.json")
        put("import_export_temp/nested/part.json")

        assertTrue(TransferFiles.delete(cache.root))

        assertFalse(file.exists())
        assertFalse(File(cache.root, "import_export_temp").exists())
    }

    @Test
    fun leavesTheRestOfTheCacheAlone() {
        put("import_export_temp/transfer.json")
        val other = put("share/abc/shared.txt")
        val similar = put("import_export_temp_old/keep.txt")

        TransferFiles.delete(cache.root)

        assertTrue(other.exists())
        assertTrue(similar.exists())
    }

    @Test
    fun isDoneWhenThereIsNothingToDeleteOrNoCache() {
        assertTrue(TransferFiles.delete(cache.root))
        assertTrue(TransferFiles.delete(null))
    }

    @Test
    fun anEndedExportClearsTheFolderAndNothingElse() {
        val file = put("import_export_temp/transfer.json")
        val other = put("share/abc/shared.txt")

        assertTrue(TransferFiles.deleteAfterExport(cache.root))

        assertFalse(file.exists())
        assertTrue(other.exists())
    }

    @Test
    fun anEndedExportLeavesTheFolderWhileAnImportOfOurOwnRuns() {
        val file = put("import_export_temp/transfer.json")
        TransferFiles.importing = true
        try {
            assertTrue(TransferFiles.deleteAfterExport(cache.root))
            assertTrue(file.exists())
        } finally {
            TransferFiles.importing = false
        }

        assertTrue(TransferFiles.deleteAfterExport(cache.root))
        assertFalse(file.exists())
    }

    @Test
    fun namesTheFolderTheLibraryWritesTo() {
        // import_export_filepaths.xml of providerevents-play-services: <cache-path path="import_export_temp">
        assertEquals("import_export_temp", TransferFiles.FOLDER)
    }
}
