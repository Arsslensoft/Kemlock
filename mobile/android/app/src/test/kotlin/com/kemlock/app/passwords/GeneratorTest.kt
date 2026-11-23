package com.kemlock.app.passwords

import com.kemlock.app.autofill.fixture
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The bundled rules list, found from wherever Gradle runs the tests. */
private fun bundledRules(): SiteRules {
    var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
    while (dir != null) {
        val file = File(dir, "src/main/assets/${SiteRules.ASSET}")
        if (file.exists()) return SiteRules.parse(file.readText())
        dir = dir.parentFile
    }
    throw IllegalStateException("No ${SiteRules.ASSET} above ${System.getProperty("user.dir")}")
}

private fun hex(text: String) = ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

// openspec: add-passwords, task 5.3
class GeneratorTest {
    @Test
    fun makesEveryRandomPasswordOfTheSharedCases() {
        val cases = JSONObject(fixture("generator/cases.json").readText()).getJSONArray("cases")
        var checked = 0
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            // The passphrases are the app's alone: AutoFill makes random passwords
            if (case.getString("kind") != "random") continue
            val c = case.getJSONObject("choices")
            val choices = PasswordChoices(
                length = c.optInt("length", DEFAULT_PASSWORD_LENGTH),
                capitals = c.optBoolean("capitals", true),
                digits = c.optBoolean("digits", true),
                symbols = c.optBoolean("symbols", true),
                avoidLookAlikes = c.optBoolean("avoidLookAlikes", true),
            )
            val rules = case.optString("rules").takeIf { it.isNotEmpty() }?.let(PasswordRules::parse)
            val made = generatePassword(FixedByteSource(hex(case.getString("bytes"))), choices, rules)
            assertEquals(case.getString("name"), case.getString("password"), made)
            checked++
        }
        assertEquals(9, checked)
    }

    @Test
    fun drawsBelowANumberWithoutFavouringTheLowValues() {
        // 250 and up would favour 0 to 5 below 10: they are drawn again
        assertEquals(3, pickBelow(FixedByteSource(byteArrayOf(250.toByte(), 255.toByte(), 13)), 10))
        // Over 256 values take two bytes, most significant first
        assertEquals(0x0102 % 1000, pickBelow(FixedByteSource(byteArrayOf(1, 2)), 1000))
    }

    @Test
    fun followsASiteThatLimitsTheLength() {
        val rules = PasswordRules.parse("minlength: 8; maxlength: 16; required: lower; required: upper; required: digit")
        repeat(50) {
            val password = generatePassword(SecureByteSource(), PasswordChoices(), rules)
            assertEquals(16, password.length)
            assertTrue(password, password.any { it.isLowerCase() } && password.any { it.isUpperCase() } && password.any { it.isDigit() })
        }
    }

    @Test
    fun leavesOutTheSymbolsASiteRefuses() {
        val rules = PasswordRules.parse("allowed: lower, upper, digit")
        repeat(50) {
            val password = generatePassword(SecureByteSource(), PasswordChoices(symbols = true), rules)
            assertTrue(password, password.all { it.isLetterOrDigit() })
        }
    }

    @Test
    fun ignoresRulesThatContradictEachOther() {
        val plan = passwordPlan(PasswordChoices(), PasswordRules.parse("minlength: 30; maxlength: 12"))
        assertEquals(passwordPlan(PasswordChoices()), plan)
    }

    @Test
    fun readsTheRulesLanguage() {
        val rules = PasswordRules.parse("minlength: 10; required: []-]; required: lower, digit; allowed: [_]; max-consecutive: 2; bogus: 3")
        assertEquals(10, rules.minLength)
        assertEquals(listOf("]-", LOWER_CHARS + DIGIT_CHARS), rules.required)
        assertEquals("_", rules.allowed)
        assertEquals(2, rules.maxConsecutive)
        assertTrue(PasswordRules.parse("bogus; ;").isEmpty)
    }

    @Test(timeout = 5000)
    fun takesAnyWhitespaceBetweenClassesAndASetNeverClosed() {
        assertEquals(listOf(LOWER_CHARS + DIGIT_CHARS), PasswordRules.parse("required: lower,\tdigit").required)
        assertEquals(listOf(UPPER_CHARS + DIGIT_CHARS), PasswordRules.parse("required: upper\ndigit").required)
        assertEquals("", PasswordRules.parse("allowed: [").allowed)
        assertEquals("ab", PasswordRules.parse("allowed: [ab").allowed)
    }

    // openspec: add-passwords, task 5.7
    @Test
    fun holdsASitesRulesToTheFieldsMaximumLength() {
        // A field that takes 16 at most gets 16, from the default 20
        val field = rulesWithMaxLength(null, 16)
        assertEquals(16, field!!.maxLength)
        assertEquals(16, generatePassword(SecureByteSource(), PasswordChoices(), field).length)
        assertEquals(12, rulesWithMaxLength("minlength: 6; maxlength: 16;", 12)!!.maxLength)
        assertEquals(16, rulesWithMaxLength("minlength: 6; maxlength: 16;", 40)!!.maxLength)
        assertEquals(PasswordRules.parse("required: digit"), rulesWithMaxLength("required: digit", -1))
        assertNull(rulesWithMaxLength(null, null))
        assertNull(rulesWithMaxLength("bogus", 0))
    }

    @Test
    fun keepsWhatIsGeneratedForTheVaultThatSavesLoginsOpenedLast() {
        val written = mapOf("personal" to 100L, "work" to 300L, "old" to 500L)
        val saving = setOf("personal", "work")
        val ordered = SavingVaults.ordered(listOf("old", "personal", "work"), { it in saving }, { true }, written::get)
        assertEquals(listOf("work", "personal"), ordered)
        // A vault without its inbox key saves nothing
        assertEquals(listOf("personal"), SavingVaults.ordered(listOf("personal", "work"), { it in saving }, { it == "personal" }, written::get))
    }

    @Test
    fun looksUpASitesRulesFromItsHostUp() {
        val sites = bundledRules()
        assertEquals(PasswordRules.parse("minlength: 6; maxlength: 16;"), sites.rulesFor("163.com"))
        assertEquals(sites.rulesFor("163.com"), sites.rulesFor("Mail.163.com."))
        // A host the list names apart from its domain takes its own rules
        assertEquals(listOf(DIGIT_CHARS, UPPER_CHARS + LOWER_CHARS), sites.rulesFor("account.xiaomi.com")!!.required)
        assertEquals(sites.rulesFor("xiaomi.com"), sites.rulesFor("www.xiaomi.com"))
        assertEquals(10, sites.rulesFor("www.access.service.gov.uk")!!.minLength)
        assertNull(sites.rulesFor("service.gov.uk"))
        assertNull(sites.rulesFor("larkspur.example"))
        assertNull(sites.rulesFor(null))
    }
}
