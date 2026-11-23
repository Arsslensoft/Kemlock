package com.kemlock.credential_transfer

import java.io.File

/**
 * The temporary files the transfer leaves in the app's cache. The library moves the exporter's
 * data through a FileProvider URI backed by `<cache>/import_export_temp/` (its
 * `import_export_filepaths.xml` names that folder, and it is a `cache-path`, so it is the app's
 * own), because a vault can be larger than Binder carries. It reads the file for the app and
 * is documented to clean up, but the data is a plain copy of every secret in it, so the plugin
 * deletes the folder itself once it has the answer, and Dart's sweep (`platform/scratch.dart`)
 * takes what a killed app left.
 */
object TransferFiles {
    /** The folder under the cache directory the library writes to. */
    const val FOLDER = "import_export_temp"

    /** Whether an import of this app is running, whose file is in [FOLDER]. Main thread only. */
    @Volatile
    var importing = false

    /**
     * What an export leaves, deleted once the answer is written or the request ends (plan
     * add-credential-exchange, task 8.5). The file an export moves its data through is the
     * importer's own, on its cache, which Kemlock can't and needn't delete; this clears Kemlock's folder
     * of whatever the library put there on its side, as insurance, and never under an import of
     * Kemlock's own that runs at the same time. True when nothing is left.
     */
    fun deleteAfterExport(cache: File?): Boolean = if (importing) true else delete(cache)

    /**
     * Deletes the transfer's folder under [cache] with whatever it holds. True when nothing is
     * left, including when there was nothing; never throws.
     */
    fun delete(cache: File?): Boolean {
        if (cache == null) return true
        return try {
            val folder = File(cache, FOLDER)
            !folder.exists() || folder.deleteRecursively()
        } catch (_: SecurityException) {
            false
        }
    }
}
