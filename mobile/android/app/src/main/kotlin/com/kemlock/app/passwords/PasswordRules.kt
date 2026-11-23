package com.kemlock.app.passwords

// A site's password rules, in the language of Apple's `passwordrules` attribute and
// password-manager-resources: `minlength: 8; maxlength: 16; required: lower; required: upper,
// digit; allowed: [-_]; max-consecutive: 2`. Read as lib/features/generator/password_rules.dart
// reads it, and the Swift parser too (openspec: add-passwords, design decision 5).

/** Characters of each named class, in the order the generator draws from them. */
const val LOWER_CHARS = "abcdefghijklmnopqrstuvwxyz"
const val UPPER_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
const val DIGIT_CHARS = "0123456789"

/** Apple's `special`: ``-~!@#$%^&*_+=`|(){}[:;"'<>,.?]`` and space. */
const val SPECIAL_CHARS = "-~!@#$%^&*_+=`|(){}[:;\"'<>,.?] "

/** Every printable ASCII character, space to tilde. */
val ASCII_PRINTABLE: String = (0x20..0x7e).joinToString("") { it.toChar().toString() }

/** A site's rules once read. A null field says nothing about it. */
data class PasswordRules(
    val minLength: Int? = null,
    val maxLength: Int? = null,
    /** Each a set of characters at least one of which the password must hold. */
    val required: List<String> = emptyList(),
    /** The characters the password may hold, besides the required ones; null when the rules name none. */
    val allowed: String? = null,
    val maxConsecutive: Int? = null,
) {
    val isEmpty: Boolean get() = minLength == null && maxLength == null && required.isEmpty() && allowed == null && maxConsecutive == null

    companion object {
        /** Reads [text]; a rule it doesn't know is skipped, as browsers do. */
        fun parse(text: String): PasswordRules {
            var minLength: Int? = null
            var maxLength: Int? = null
            var maxConsecutive: Int? = null
            val required = mutableListOf<String>()
            var allowed: String? = null
            for (rule in splitRules(text)) {
                val colon = rule.indexOf(':')
                if (colon < 0) continue
                val name = rule.substring(0, colon).trim().lowercase()
                val value = rule.substring(colon + 1).trim()
                when (name) {
                    "minlength" -> minLength = value.toIntOrNull()
                    "maxlength" -> maxLength = value.toIntOrNull()
                    "max-consecutive" -> maxConsecutive = value.toIntOrNull()
                    "required" -> classes(value).takeIf { it.isNotEmpty() }?.let { required += it }
                    "allowed" -> allowed = unionOf(listOfNotNull(allowed, classes(value)))
                }
            }
            return PasswordRules(minLength, maxLength, required, allowed, maxConsecutive)
        }

        /** Splits at the semicolons outside brackets: a custom class may hold one. */
        private fun splitRules(text: String): List<String> {
            val rules = mutableListOf<String>()
            var start = 0
            var inClass = false
            var i = 0
            while (i < text.length) {
                val c = text[i]
                if (c == '[' && !inClass) {
                    inClass = true
                    // A ] right after the opening bracket is a character of the class
                    if (i + 1 < text.length && text[i + 1] == ']') i++
                } else if (c == ']' && inClass) {
                    inClass = false
                } else if (c == ';' && !inClass) {
                    rules += text.substring(start, i)
                    start = i + 1
                }
                i++
            }
            rules += text.substring(start)
            return rules.filter { it.isNotBlank() }
        }

        private val classEnd = Regex("[,\\s\\[]")

        /** The characters of a comma-separated list of classes and `[...]` sets. */
        private fun classes(value: String): String {
            val parts = mutableListOf<String>()
            var i = 0
            while (i < value.length) {
                val c = value[i]
                // Classes are separated by commas and whitespace of any kind
                if (c == ',' || c.isWhitespace()) {
                    i++
                } else if (c == '[') {
                    // A custom set: everything up to the closing bracket, a ] first being one of its characters
                    var end = if (i + 2 <= value.length) value.indexOf(']', i + 2) else -1
                    if (end < 0) end = value.length
                    parts += value.substring(minOf(i + 1, end), end)
                    i = end + 1
                } else {
                    var end = classEnd.find(value, i)?.range?.first ?: -1
                    if (end < 0) end = value.length
                    parts += when (value.substring(i, end).lowercase()) {
                        "lower" -> LOWER_CHARS
                        "upper" -> UPPER_CHARS
                        "digit" -> DIGIT_CHARS
                        "special" -> SPECIAL_CHARS
                        "ascii-printable", "unicode" -> ASCII_PRINTABLE
                        else -> ""
                    }
                    i = end
                }
            }
            return unionOf(parts)
        }
    }
}

/**
 * A site's rules as [text] writes them, held to a field's [maxLength] when it takes fewer
 * characters than they allow; null when neither says anything, so the choices are made alone.
 */
fun rulesWithMaxLength(text: String?, maxLength: Int?): PasswordRules? {
    val rules = text?.let(PasswordRules::parse) ?: PasswordRules()
    val capped = if (maxLength != null && maxLength > 0 && (rules.maxLength == null || rules.maxLength > maxLength)) rules.copy(maxLength = maxLength) else rules
    return capped.takeUnless { it.isEmpty }
}

/** [sets] joined, each character once, in the order they first appear. */
fun unionOf(sets: List<String>): String {
    val seen = HashSet<Int>()
    val out = StringBuilder()
    for (set in sets) {
        set.codePoints().forEach { if (seen.add(it)) out.appendCodePoint(it) }
    }
    return out.toString()
}

/** [a]'s characters that are also in [b], in [a]'s order. */
fun intersect(a: String, b: String): String {
    val inB = b.codePoints().toArray().toHashSet()
    val out = StringBuilder()
    a.codePoints().forEach { if (it in inB) out.appendCodePoint(it) }
    return out.toString()
}
