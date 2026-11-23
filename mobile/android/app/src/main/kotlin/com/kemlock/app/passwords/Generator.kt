package com.kemlock.app.passwords

import java.security.SecureRandom

// Random passwords, made as lib/features/generator/generator.dart makes them, so that equal
// choices, rules and random bytes give an equal password (openspec: password-generator;
// add-passwords, design decision 5). The shared cases are test/fixtures/generator/cases.json.

/** The symbols the generator uses by default. */
const val GENERATOR_SYMBOLS = "!#%&-_?"

/** Characters people mistake for one another, left out when asked. */
const val LOOK_ALIKES = "0O1lI"

const val MIN_PASSWORD_LENGTH = 8
const val MAX_PASSWORD_LENGTH = 64
const val DEFAULT_PASSWORD_LENGTH = 20

/** Where random bytes come from: the phone's secure source, or a fixed stream in the tests. */
fun interface ByteSource {
    /** A byte, 0 to 255. */
    fun nextByte(): Int
}

/** The phone's cryptographically secure random source. */
class SecureByteSource(private val random: SecureRandom = SecureRandom()) : ByteSource {
    override fun nextByte(): Int = random.nextInt(256)
}

/** A fixed stream of bytes, for the shared test cases. Running out is an error. */
class FixedByteSource(private val bytes: ByteArray) : ByteSource {
    private var next = 0

    override fun nextByte(): Int {
        check(next < bytes.size) { "Out of random bytes after $next" }
        return bytes[next++].toInt() and 0xff
    }
}

/**
 * A number below [n] with every value as likely: bytes that would favour the low values are
 * drawn again. Up to 256 values from one byte, more from two, most significant first.
 */
fun pickBelow(source: ByteSource, n: Int): Int {
    require(n > 0) { "n must be positive: $n" }
    if (n <= 256) {
        val limit = 256 - 256 % n
        while (true) {
            val b = source.nextByte()
            if (b < limit) return b % n
        }
    }
    val limit = 65536 - 65536 % n
    while (true) {
        val v = (source.nextByte() shl 8) or source.nextByte()
        if (v < limit) return v % n
    }
}

/** What a random password is made of; AutoFill makes them with the defaults. */
data class PasswordChoices(
    val length: Int = DEFAULT_PASSWORD_LENGTH,
    val capitals: Boolean = true,
    val digits: Boolean = true,
    val symbols: Boolean = true,
    val avoidLookAlikes: Boolean = true,
)

/** The sets one character of each must be in the password, the alphabet the rest is drawn from, its length and the longest run allowed. */
data class PasswordPlan(val required: List<String>, val alphabet: String, val length: Int, val maxConsecutive: Int?)

private fun withoutLookAlikes(chars: String, avoid: Boolean): String =
    if (avoid) chars.filter { it !in LOOK_ALIKES } else chars

/**
 * The plan for [choices] under [rules]: each chosen set keeps what the site allows, and every
 * set the site requires that no kept set lies within is added. Rules that can't be met are
 * left out, and [choices] made alone.
 */
fun passwordPlan(choices: PasswordChoices, rules: PasswordRules? = null): PasswordPlan {
    val avoid = choices.avoidLookAlikes
    val chosen = listOfNotNull(
        withoutLookAlikes(LOWER_CHARS, avoid),
        if (choices.capitals) withoutLookAlikes(UPPER_CHARS, avoid) else null,
        if (choices.digits) withoutLookAlikes(DIGIT_CHARS, avoid) else null,
        if (choices.symbols) GENERATOR_SYMBOLS else null,
    )
    val plain = PasswordPlan(chosen, unionOf(chosen), choices.length.coerceIn(MIN_PASSWORD_LENGTH, MAX_PASSWORD_LENGTH), null)
    if (rules == null || rules.isEmpty) return plain

    // What the site takes: what it allows and requires, or any printable character when it says neither
    val allowed = if (rules.allowed != null || rules.required.isNotEmpty()) unionOf(rules.required + listOfNotNull(rules.allowed)) else ASCII_PRINTABLE
    val kept = chosen.map { intersect(it, allowed) }.filter { it.isNotEmpty() }
    val ours = unionOf(chosen)
    val siteRequired = mutableListOf<String>()
    for (set in rules.required) {
        // From the site's set, the characters this generator uses when any, else the set without space, else all of it
        val preferred = withoutLookAlikes(intersect(set, ours), avoid)
        val fallback = withoutLookAlikes(set.replace(" ", ""), avoid)
        val pick = when {
            preferred.isNotEmpty() -> preferred
            fallback.isNotEmpty() -> fallback
            else -> set
        }
        if (kept.none { intersect(it, set).length == it.length }) siteRequired += pick
    }
    val required = kept + siteRequired
    val min = maxOf(rules.minLength ?: 1, required.size)
    val top = rules.maxLength ?: MAX_PASSWORD_LENGTH
    val length = choices.length.coerceIn(min, maxOf(min, top))
    if (required.isEmpty() || required.any { it.isEmpty() } || (rules.maxLength != null && rules.maxLength < min) || length > top) {
        return plain
    }
    return PasswordPlan(required, unionOf(required), length, rules.maxConsecutive)
}

/**
 * A random password: one character from each required set first, then characters from the
 * whole alphabet to the length, then shuffled (Fisher–Yates), every draw from [source] by
 * [pickBelow]. A character that would make a run longer than the rules allow is drawn again.
 */
fun generatePassword(source: ByteSource, choices: PasswordChoices = PasswordChoices(), rules: PasswordRules? = null): String {
    val plan = passwordPlan(choices, rules)
    val alphabet = plan.alphabet.codePoints().toArray()
    val chars = mutableListOf<Int>()
    for (set in plan.required) {
        val points = set.codePoints().toArray()
        chars += points[pickBelow(source, points.size)]
    }
    while (chars.size < plan.length) chars += alphabet[pickBelow(source, alphabet.size)]
    for (i in chars.size - 1 downTo 1) {
        val j = pickBelow(source, i + 1)
        val swap = chars[i]
        chars[i] = chars[j]
        chars[j] = swap
    }
    val most = plan.maxConsecutive
    if (most != null && most > 0 && alphabet.size > 1) {
        var run = 1
        for (i in 1 until chars.size) {
            run = if (chars[i] == chars[i - 1]) run + 1 else 1
            while (run > most) {
                chars[i] = alphabet[pickBelow(source, alphabet.size)]
                run = if (chars[i] == chars[i - 1]) run else 1
            }
        }
    }
    return buildString { chars.forEach { appendCodePoint(it) } }
}
