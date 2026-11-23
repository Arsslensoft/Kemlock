package com.kemlock.app.autofill

import java.io.File

/** A file of mobile/test/fixtures, found from wherever Gradle runs the tests. */
fun fixture(path: String): File {
    var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
    while (dir != null) {
        val file = File(dir, "test/fixtures/$path")
        if (file.exists()) return file
        dir = dir.parentFile
    }
    throw IllegalStateException("No test/fixtures/$path above ${System.getProperty("user.dir")}")
}
