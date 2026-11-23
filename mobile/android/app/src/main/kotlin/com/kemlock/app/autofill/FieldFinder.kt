package com.kemlock.app.autofill

/**
 * A view of the screen being filled, as the autofill service sees it, reduced to what finding
 * a code field needs, so the JVM tests can build screens by hand. [T] is the id the framework
 * fills by (an `AutofillId` on the phone).
 */
interface FieldNode<T> {
    val id: T?
    val autofillHints: List<String>
    val htmlTag: String?
    val htmlAttributes: Map<String, String>
    val idEntry: String?
    val hint: String?
    val contentDescription: String?
    val inputType: Int
    val maxLength: Int
    val visible: Boolean
    val isText: Boolean
    val focused: Boolean
    val webDomain: String?

    /** The scheme the browser loaded [webDomain] over, `https` or `http`, when it says. */
    val webScheme: String?
    val children: List<FieldNode<T>>

    /** The text the field holds, which a save request reads once the form is sent. */
    val value: String? get() = null
}

/** A field to fill: the whole code, or the code's character at [character] for a row of one-character boxes. */
data class CodeField<T>(val id: T, val character: Int?)

/**
 * The code fields found on a screen, and the website they belong to, when they belong to one: the
 * nearest web domain above the focused code field, or the first. A frame from another site names
 * its own, so only the fields of that one site are kept. [webScheme] is the scheme the browser
 * loaded that site over, as the node that names it says, `https` or `http`, when it says.
 */
data class FoundFields<T>(val fields: List<CodeField<T>>, val webDomain: String?, val webScheme: String? = null)

/** What a field of a sign-in, sign-up or change-password form is for. */
enum class LoginRole { USERNAME, PASSWORD, NEW_PASSWORD }

/**
 * The login fields of one site found on a screen (openspec: add-passwords, design decision
 * 10): its username, its current password, and its new password with the confirmation, in
 * screen order. [webDomain] is the site's, the nearest web domain above the field the person is
 * in, or above the first password; a frame from another site is a site of its own. [focused]
 * is what the field the person is in is for, when it is one of these. [newPasswordMaxLength] is
 * the fewest characters a new password field takes, and [newPasswordRules] the rules a page
 * states in its `passwordrules` attribute, when they say so. [webScheme] is the scheme the browser
 * loaded the site over, as the node that names it says, `https` or `http`, when it says.
 */
data class LoginFields<T>(
    val username: T?,
    val password: T?,
    val newPasswords: List<T>,
    val webDomain: String?,
    val focused: LoginRole?,
    val newPasswordMaxLength: Int? = null,
    val newPasswordRules: String? = null,
    val webScheme: String? = null,
) {
    val isEmpty: Boolean get() = username == null && password == null && newPasswords.isEmpty()

    /** A sign-up or change-password form, which a strong password is suggested for. */
    val asksNewPassword: Boolean get() = newPasswords.isNotEmpty()

    /** Every field found, to save from and to fill. */
    val all: List<T> get() = listOfNotNull(username, password) + newPasswords
}

/**
 * Finds one-time code fields: by the autofill hints apps set (`2faAppOTPCode`, `smsOTPCode`
 * and the rest of `androidx.autofill.HintConstants`), by `autocomplete="one-time-code"` on
 * the web, which Chrome hands over as a hint, and by Chrome's own prediction that a field
 * wants one (`ONE_TIME_CODE`). Otherwise by a narrow guess: a field whose id, hint or label
 * says OTP or 2FA, or a short numeric one that says code or verification. A row of four to
 * ten one-character boxes gets a character in each, whatever it says. When the person asks
 * for autofill from a field's menu, the field they're in is filled even if nothing says code.
 */
object FieldFinder {
    private val otpHints = setOf("2faappotpcode", "tfaappotpcode", "smsotpcode", "emailotpcode", "one-time-code", "onetimecode", "otp", "otpcode")
    private val perCharacterHint = Regex("^(?:smsotpcode|2faappotpcode|emailotpcode|otp)([1-9])$")

    // What Chrome predicts of a field it hands a third-party service, by its own field types.
    private val chromePredictions = listOf("computed-autofill-hints", "crowdsourcing-autofill-hints", "ua-autofill-hints", "crowdsourcing-predictions-autofill-hints")
    private const val CHROME_ONE_TIME_CODE = "ONE_TIME_CODE"

    // Words that may mean a one-time code, in English and French, on a short or numeric field;
    // so does the word code itself, as one of the words of a name (smsCode, code_input).
    private val codeWords = Regex(
        "(?:verification|verify|authenticat|security[-_ ]?code|auth[-_ ]?code|passcode|code de s[ée]curit[ée]|token)",
        RegexOption.IGNORE_CASE,
    )

    // Words that say so on their own, taken as whole words of the name: a field called otp or
    // twoFactorCode wants a code however long it is; one called footprint doesn't.
    private val strongWords = setOf("otp", "totp", "2fa", "tfa", "mfa", "onetime", "twofactor", "2step")
    private val strongPairs = setOf("one time", "two factor", "verification code", "code verification", "authentication code", "auth code")
    private val wordBreak = Regex("(?<=\\p{Ll})(?=\\p{Lu})|(?<=\\p{Lu})(?=\\p{Lu}\\p{Ll})|[^\\p{L}\\p{N}]+")

    // Codes these fields want aren't one-time codes.
    private val otherCodes = Regex(
        "(?:zip|postal|post[-_ ]?code|promo|coupon|voucher|discount|gift|referral|invite|invitation|country|area|phone|captcha|" +
            "card|cvv|cvc|security[-_ ]?question|pin[-_ ]?code|bar[-_ ]?code|qr|source[-_ ]?code|code[-_ ]?postal|parrainage|" +
            "recovery|backup|secours)",
        RegexOption.IGNORE_CASE,
    )

    private const val CLASS_MASK = 0x0000000f
    private const val CLASS_TEXT = 0x00000001
    private const val CLASS_NUMBER = 0x00000002
    private const val VARIATION_MASK = 0x00000ff0
    private const val TEXT_PASSWORD = 0x00000080
    private const val TEXT_WEB_PASSWORD = 0x000000e0
    private const val TEXT_VISIBLE_PASSWORD = 0x00000090
    private const val TEXT_EMAIL = 0x00000020
    private const val TEXT_WEB_EMAIL = 0x000000d0

    /**
     * The code fields of the screen under [roots]. [manual] is a request the person made from a
     * field's menu: with no code field found, the field they're in is filled all the same.
     */
    fun <T> find(roots: List<FieldNode<T>>, manual: Boolean = false): FoundFields<T> {
        val explicit = mutableListOf<Pair<FieldNode<T>, Int?>>()
        val guessed = mutableListOf<FieldNode<T>>()
        val boxes = mutableListOf<FieldNode<T>>()
        var focused: FieldNode<T>? = null
        // Each field's site: the nearest web domain at or above it, so a frame from another site counts as that site
        val siteOf = HashMap<T, Site?>()

        fun visit(node: FieldNode<T>, inherited: Site?) {
            val site = siteNamedBy(node) ?: inherited
            if (node.id != null && node.visible && node.isText) {
                siteOf[node.id!!] = site
                if (node.focused && focused == null) focused = node
                val hints = node.autofillHints.map { it.lowercase() }
                val position = hints.firstNotNullOfOrNull { perCharacterHint.find(it)?.groupValues?.get(1)?.toInt() }
                when {
                    position != null -> explicit += node to position - 1
                    hints.any { it in otpHints } -> explicit += node to null
                    node.htmlAttributes["autocomplete"]?.lowercase()?.split(' ')?.contains("one-time-code") == true -> explicit += node to null
                    chromeSaysCode(node) -> explicit += node to null
                    looksLikeCode(node) -> guessed += node
                    looksLikeBox(node) -> boxes += node
                }
            }
            node.children.forEach { visit(it, site) }
        }
        roots.forEach { visit(it, null) }

        val inFocus = focused
        // The site being filled is the focused field's, else the first found field's; any other site's fields are left alone
        val candidates = explicit.map { it.first } + guessed + boxes
        val anchor = candidates.firstOrNull { it === inFocus } ?: candidates.firstOrNull() ?: inFocus
        val site = anchor?.let { siteOf[it.id!!] }
        val onSite = { node: FieldNode<T> -> siteOf[node.id!!] == site }
        val siteExplicit = explicit.filter { onSite(it.first) }
        val siteGuessed = guessed.filter(onSite)
        val siteBoxes = boxes.filter(onSite)
        val fields: List<CodeField<T>> = when {
            siteExplicit.isNotEmpty() -> fieldsOf(siteExplicit)
            siteGuessed.isNotEmpty() -> fieldsOf(siteGuessed.map { it to null })
            siteBoxes.size in 4..10 -> siteBoxes.mapIndexed { i, node -> CodeField<T>(node.id!!, i) }
            manual && inFocus != null && onSite(inFocus) -> listOf(CodeField<T>(inFocus.id!!, null))
            else -> emptyList()
        }
        val found = site.takeIf { fields.isNotEmpty() }
        return FoundFields(fields, found?.domain, found?.scheme)
    }

    /**
     * A site, as the nearest node with a web domain at or above a field names it: that domain,
     * with the scheme the same node gives, never another node's. An `http` frame of a site is
     * not its `https` page.
     */
    private data class Site(val domain: String, val scheme: String?)

    private fun <T> siteNamedBy(node: FieldNode<T>): Site? = node.webDomain?.takeIf { it.isNotBlank() }?.let { Site(it, node.webScheme) }

    // What apps and Chrome say a login field is: autofill hints (View's and HintConstants'), the
    // autocomplete tokens Chrome hands over as hints, and Chrome's own predictions.
    private val usernameHints = setOf("username", "emailaddress", "email", "newusername", "new-username")
    private val passwordHints = setOf("password", "current-password")
    private val newPasswordHints = setOf("newpassword", "new-password")
    private val chromeUsernames = setOf("USERNAME", "USERNAME_AND_EMAIL_ADDRESS", "EMAIL_ADDRESS")
    private val chromePasswords = setOf("PASSWORD")
    private val chromeNewPasswords = setOf("NEW_PASSWORD", "ACCOUNT_CREATION_PASSWORD", "CONFIRMATION_PASSWORD", "PROBABLY_NEW_PASSWORD")

    // Words beside a password that make it a new one, or its confirmation, in English and French.
    private val newOnlyWords = setOf("new", "nouveau", "nouvelle")
    private val confirmWords = setOf("confirm", "confirmation", "repeat", "retype", "confirmer")
    private val searchWords = setOf("search", "query", "recherche", "rechercher")

    private const val CLASS_NUMBER_PASSWORD = 0x00000010

    /**
     * A field and what it says it is for, with whether it said so outright or only by its type,
     * whether a new password is only the confirmation of another, and whether a password says it
     * is the current one.
     */
    private class LoginCandidate<T>(
        val node: FieldNode<T>,
        val role: LoginRole?,
        val outright: Boolean,
        val confirmation: Boolean = false,
        val current: Boolean = false,
    )

    /**
     * The login fields of the screen under [roots]: by the hints apps set, the autocomplete
     * tokens and predictions Chrome hands over, a password's input type or `type=password`, and
     * words such as new and confirm beside a password. A username is the field that says it is
     * one, else the email or text field nearest before the first password; a username alone
     * counts only when the field says so outright, as on a first page that asks for the email.
     * Two passwords that say nothing are a new password and its confirmation; three, the current
     * one and the two new ones.
     */
    fun <T> findLogin(roots: List<FieldNode<T>>): LoginFields<T> {
        val candidates = mutableListOf<LoginCandidate<T>>()
        val siteOf = HashMap<T, Site?>()
        var focused: FieldNode<T>? = null

        fun visit(node: FieldNode<T>, inherited: Site?) {
            val site = siteNamedBy(node) ?: inherited
            if (node.id != null && node.visible && node.isText) {
                siteOf[node.id!!] = site
                if (node.focused && focused == null) focused = node
                loginCandidate(node)?.let { candidates += it }
            }
            node.children.forEach { visit(it, site) }
        }
        roots.forEach { visit(it, null) }

        val inFocus = focused
        val roled = candidates.filter { it.role != null }
        val anchor = roled.firstOrNull { it.node === inFocus }
            ?: roled.firstOrNull { it.role != LoginRole.USERNAME }
            ?: roled.firstOrNull { it.role == LoginRole.USERNAME && it.outright }
            ?: return LoginFields(null, null, emptyList(), null, null)
        val site = siteOf[anchor.node.id!!]
        val onSite = candidates.filter { siteOf[it.node.id!!] == site }

        var passwords = onSite.filter { it.role == LoginRole.PASSWORD }
        var news = onSite.filter { it.role == LoginRole.NEW_PASSWORD }
        // Passwords none of which says it is new: a sign-up form's two, or a change form's three
        if (news.isEmpty() && passwords.size >= 2) {
            news = if (passwords.size == 2) passwords else passwords.drop(1)
            passwords = if (passwords.size == 2) emptyList() else passwords.take(1)
        }
        // A sign-up form's password beside its confirmation is new too; a change form's current one says so
        if (passwords.size == 1 && news.isNotEmpty() && news.all { it.confirmation } && !passwords[0].current) {
            val beside = passwords[0]
            news = onSite.filter { it === beside || it in news }
            passwords = emptyList()
        }
        val firstPassword = onSite.indexOfFirst { it in passwords || it in news }
        val before = if (firstPassword < 0) onSite else onSite.take(firstPassword)
        val username = onSite.firstOrNull { it.role == LoginRole.USERNAME && it.outright }
            ?: before.lastOrNull { it.role == LoginRole.USERNAME }.takeIf { firstPassword >= 0 }
            ?: before.lastOrNull { it.role == null }.takeIf { firstPassword >= 0 }

        val password = passwords.firstOrNull()
        val newIds = news.map { it.node.id!! }
        val focusedRole = when {
            inFocus == null -> null
            username?.node === inFocus -> LoginRole.USERNAME
            password?.node === inFocus -> LoginRole.PASSWORD
            news.any { it.node === inFocus } -> LoginRole.NEW_PASSWORD
            else -> null
        }
        if (username == null && password == null && newIds.isEmpty()) return LoginFields(null, null, emptyList(), null, null)
        val maxLength = news.mapNotNull { maxLengthOf(it.node).takeIf { length -> length > 0 } }.minOrNull()
        val rules = news.firstNotNullOfOrNull { it.node.htmlAttributes["passwordrules"]?.takeIf(String::isNotBlank) }
        return LoginFields(username?.node?.id, password?.node?.id, newIds, site?.domain, focusedRole, maxLength, rules, site?.scheme)
    }

    /**
     * What [node] is for on a login form, or a text field that may be its username (role null);
     * null for a field that is none of these, such as a one-time code or a search box.
     */
    private fun <T> loginCandidate(node: FieldNode<T>): LoginCandidate<T>? {
        if (node.htmlTag != null && node.htmlTag?.lowercase() != "input") return null
        val hints = node.autofillHints.map { it.lowercase() }
        if (hints.any { it in otpHints || perCharacterHint.matches(it) }) return null
        val autocomplete = node.htmlAttributes["autocomplete"]?.lowercase()?.split(' ').orEmpty()
        if ("one-time-code" in autocomplete || chromeSaysCode(node)) return null
        val split = splitWords(wordsOf(node))
        val confirms = split.any { it in confirmWords } && split.none { it in newOnlyWords }
        val saysNew = confirms || split.any { it in newOnlyWords }
        val predicted = chromePredictions.flatMap { node.htmlAttributes[it]?.split(',', ' ').orEmpty() }.map { it.trim().uppercase() }

        fun candidate(role: LoginRole, outright: Boolean) =
            LoginCandidate(node, role, outright, confirmation = role == LoginRole.NEW_PASSWORD && confirms)
        fun outright(role: LoginRole) = candidate(role, true)
        if ("CONFIRMATION_PASSWORD" in predicted) return LoginCandidate(node, LoginRole.NEW_PASSWORD, true, confirmation = true)
        when {
            hints.any { it in newPasswordHints } || "new-password" in autocomplete -> return outright(LoginRole.NEW_PASSWORD)
            "current-password" in autocomplete -> return LoginCandidate(node, LoginRole.PASSWORD, true, current = true)
            hints.any { it in passwordHints } -> return outright(if (saysNew) LoginRole.NEW_PASSWORD else LoginRole.PASSWORD)
            hints.any { it in usernameHints } || autocomplete.any { it == "username" || it == "email" } -> return outright(LoginRole.USERNAME)
        }
        predicted.firstNotNullOfOrNull {
            when (it) {
                in chromeNewPasswords -> LoginRole.NEW_PASSWORD
                in chromePasswords -> if (saysNew) LoginRole.NEW_PASSWORD else LoginRole.PASSWORD
                in chromeUsernames -> LoginRole.USERNAME
                else -> null
            }
        }?.let { return outright(it) }

        val htmlType = node.htmlAttributes["type"]?.lowercase()
        val inputClass = node.inputType and CLASS_MASK
        val variation = node.inputType and VARIATION_MASK
        val passwordType = htmlType == "password" ||
            (inputClass == CLASS_TEXT && variation in setOf(TEXT_PASSWORD, TEXT_WEB_PASSWORD, TEXT_VISIBLE_PASSWORD)) ||
            (inputClass == CLASS_NUMBER && variation == CLASS_NUMBER_PASSWORD)
        if (passwordType) return candidate(if (saysNew) LoginRole.NEW_PASSWORD else LoginRole.PASSWORD, false)
        if (htmlType == "email" || (inputClass == CLASS_TEXT && variation in setOf(TEXT_EMAIL, TEXT_WEB_EMAIL))) {
            return candidate(LoginRole.USERNAME, false)
        }
        // A plain text field may be the username before a password, unless it is a code or a search
        if (htmlType != null && htmlType != "text") return null
        if (inputClass != CLASS_TEXT || split.any { it in searchWords } || looksLikeCode(node)) return null
        return LoginCandidate(node, null, false)
    }

    /** Chrome predicts, from its own heuristics or what its servers learned of the form, that the field wants a one-time code. */
    private fun <T> chromeSaysCode(node: FieldNode<T>): Boolean = chromePredictions.any { attribute ->
        node.htmlAttributes[attribute]?.split(',', ' ')?.any { it.trim().uppercase() == CHROME_ONE_TIME_CODE } == true
    }

    /** One box of a row of one-character boxes, which a code is typed into a character at a time. */
    private fun <T> looksLikeBox(node: FieldNode<T>): Boolean {
        if (maxLengthOf(node) != 1 || !mayHoldACode(node)) return false
        return !otherCodes.containsMatchIn(wordsOf(node))
    }

    /** One field for the whole code, or a character in each of a row of one-character boxes. */
    private fun <T> fieldsOf(found: List<Pair<FieldNode<T>, Int?>>): List<CodeField<T>> {
        if (found.any { it.second != null }) {
            return found.filter { it.second != null }.sortedBy { it.second }.map { CodeField(it.first.id!!, it.second) }
        }
        val boxes = found.filter { maxLengthOf(it.first) == 1 }
        if (boxes.size in 4..10) return boxes.mapIndexed { i, (node, _) -> CodeField(node.id!!, i) }
        return listOf(CodeField(found.first().first.id!!, null))
    }

    private fun <T> looksLikeCode(node: FieldNode<T>): Boolean {
        if (!mayHoldACode(node)) return false
        val words = wordsOf(node)
        if (otherCodes.containsMatchIn(words)) return false
        val split = splitWords(words)
        if (saysOneTimeCode(split)) return true
        val inputClass = node.inputType and CLASS_MASK
        val htmlType = node.htmlAttributes["type"]?.lowercase()
        val short = maxLengthOf(node) in 1..10
        val numeric = inputClass == CLASS_NUMBER || htmlType == "number" || htmlType == "tel" ||
            node.htmlAttributes["inputmode"]?.lowercase() == "numeric"
        return (short || numeric) && (codeWords.containsMatchIn(words) || "code" in split)
    }

    /** A text, number or phone field, not an email address or a password. */
    private fun <T> mayHoldACode(node: FieldNode<T>): Boolean {
        if (node.htmlTag != null && node.htmlTag?.lowercase() != "input") return false
        val htmlType = node.htmlAttributes["type"]?.lowercase()
        if (htmlType != null && htmlType !in setOf("text", "number", "tel")) return false
        val inputClass = node.inputType and CLASS_MASK
        val variation = node.inputType and VARIATION_MASK
        if (inputClass == CLASS_TEXT && variation in setOf(TEXT_EMAIL, TEXT_WEB_EMAIL)) return false
        if (inputClass == CLASS_TEXT && variation in setOf(TEXT_PASSWORD, TEXT_WEB_PASSWORD, TEXT_VISIBLE_PASSWORD)) return false
        return true
    }

    /** What a field says of itself: its id, its hint, what a screen reader reads, and its name, id and labels on the web. */
    private fun <T> wordsOf(node: FieldNode<T>): String = listOfNotNull(
        node.idEntry,
        node.hint,
        node.contentDescription,
        node.htmlAttributes["name"],
        node.htmlAttributes["id"],
        node.htmlAttributes["placeholder"],
        node.htmlAttributes["aria-label"],
        node.htmlAttributes["label"],
    ).joinToString(" ")

    /** The words of a name, lowercased: `twoFactorCode` and `two_factor-code` are both two, factor, code. */
    private fun splitWords(words: String): List<String> =
        words.split(wordBreak).filter { it.isNotEmpty() }.map { it.lowercase().replace('é', 'e') }

    /** Whether the words of a name say one-time code by a word that can mean nothing else: OTP, 2FA, two-factor, verification code. */
    private fun saysOneTimeCode(split: List<String>): Boolean {
        if (split.any { it in strongWords }) return true
        return split.zipWithNext().any { (a, b) -> "$a $b" in strongPairs } ||
            split.windowed(3).any { (a, de, b) -> de == "de" && a == "code" && b == "verification" }
    }

    private fun <T> maxLengthOf(node: FieldNode<T>): Int =
        node.maxLength.takeIf { it > 0 } ?: node.htmlAttributes["maxlength"]?.toIntOrNull() ?: -1
}
