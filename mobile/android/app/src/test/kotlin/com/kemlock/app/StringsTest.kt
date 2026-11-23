package com.kemlock.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The app's resources, found from wherever Gradle runs the tests. */
private fun res(): File {
    var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
    while (dir != null) {
        val res = File(dir, "src/main/res")
        if (File(res, "values").isDirectory) return res
        dir = dir.parentFile
    }
    throw IllegalStateException("No src/main/res above ${System.getProperty("user.dir")}")
}

private val string = Regex("""<string\s+name="([^"]+)"([^>]*)>(.*?)</string>""", RegexOption.DOT_MATCHES_ALL)
private val placeholder = Regex("""%\d+\$[sd]""")

/** Each translatable string of [file] by name, with the placeholders its text holds. */
private fun strings(file: File): Map<String, List<String>> = string.findAll(file.readText())
    .filterNot { "translatable=\"false\"" in it.groupValues[2] }
    .associate { it.groupValues[1] to placeholder.findAll(it.groupValues[3]).map { p -> p.value }.sorted().toList() }

// openspec: add-passwords, task 5.9: the French strings name every English one, with the same placeholders
class StringsTest {
    @Test
    fun everyStringHasItsFrenchWithTheSamePlaceholders() {
        val values = File(res(), "values")
        val french = File(res(), "values-fr")
        var checked = 0
        for (file in values.listFiles().orEmpty().filter { it.extension == "xml" }.sortedBy { it.name }) {
            val english = strings(file)
            if (english.isEmpty()) continue
            val translated = File(french, file.name)
            assertTrue("values-fr/${file.name} is missing", translated.exists())
            val frenchStrings = strings(translated)
            assertEquals(file.name, english.keys.sorted(), frenchStrings.keys.sorted())
            for ((name, args) in english) assertEquals("$name in ${file.name}", args, frenchStrings[name])
            checked += english.size
        }
        // The French files hold nothing the English ones don't
        for (file in french.listFiles().orEmpty().filter { it.extension == "xml" }) {
            assertTrue("values/${file.name} is missing", File(values, file.name).exists())
        }
        assertTrue("only $checked strings found", checked > 50)
    }
}
