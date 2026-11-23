package com.kemlock.app.autofill

import com.kemlock.app.passwords.InboxApp
import com.kemlock.app.passwords.SaveDecision
import com.kemlock.app.passwords.SaveFields
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A view built by hand, as the structure Android hands the service would describe it. */
private data class Node(
    override val id: String? = null,
    override val autofillHints: List<String> = emptyList(),
    override val htmlTag: String? = null,
    override val htmlAttributes: Map<String, String> = emptyMap(),
    override val idEntry: String? = null,
    override val hint: String? = null,
    override val contentDescription: String? = null,
    override val inputType: Int = TEXT,
    override val maxLength: Int = -1,
    override val visible: Boolean = true,
    override val isText: Boolean = true,
    override val focused: Boolean = false,
    override val webDomain: String? = null,
    override val webScheme: String? = null,
    override val children: List<FieldNode<String>> = emptyList(),
    override val value: String? = null,
) : FieldNode<String>

private const val TEXT = 0x1
private const val NUMBER = 0x2
private const val TEXT_PASSWORD = 0x81
private const val TEXT_EMAIL = 0x21

private fun screen(vararg nodes: Node, webDomain: String? = null, webScheme: String? = null) =
    listOf(Node(isText = false, webDomain = webDomain, webScheme = webScheme, children = nodes.toList()))

private fun find(vararg nodes: Node, webDomain: String? = null, webScheme: String? = null, manual: Boolean = false) =
    FieldFinder.find(screen(*nodes, webDomain = webDomain, webScheme = webScheme), manual)

private val nothing = emptyList<CodeField<String>>()

class FieldFinderTest {
    @Test
    fun findsAFieldByTheOtpHintsAppsSet() {
        for (hint in listOf("2faAppOTPCode", "smsOTPCode", "emailOTPCode", "one-time-code")) {
            val found = find(Node("user", autofillHints = listOf("username")), Node("code", autofillHints = listOf(hint)))
            assertEquals(hint, listOf(CodeField("code", null)), found.fields)
        }
    }

    @Test
    fun findsAWebFieldByItsAutocomplete() {
        val found = find(
            Node("code", htmlTag = "input", htmlAttributes = mapOf("autocomplete" to "one-time-code", "type" to "text")),
            webDomain = "github.com",
        )
        assertEquals(listOf(CodeField("code", null)), found.fields)
        assertEquals("github.com", found.webDomain)
    }

    @Test
    fun readsTheSchemeOfTheNodeThatNamesTheSite() {
        val code = Node("code", htmlTag = "input", htmlAttributes = mapOf("autocomplete" to "one-time-code"))
        assertEquals("https", find(code, webDomain = "github.com", webScheme = "https").webScheme)
        assertEquals("http", find(code, webDomain = "github.com", webScheme = "http").webScheme)
        assertNull(find(code, webDomain = "github.com").webScheme)
        // The scheme goes with the site: a field in a frame is the frame's site, over the frame's scheme
        val inFrame = find(Node(isText = false, webDomain = "ads.example", webScheme = "https", children = listOf(code)), webDomain = "github.com", webScheme = "http")
        assertEquals("ads.example", inFrame.webDomain)
        assertEquals("https", inFrame.webScheme)
        // A field of the page is the page's, whatever a frame beside it says
        val beside = find(code, Node(isText = false, webDomain = "github.com", webScheme = "https", children = listOf(Node("other"))), webDomain = "github.com", webScheme = "http")
        assertEquals("github.com", beside.webDomain)
        assertEquals("http", beside.webScheme)
    }

    @Test
    fun takesAnHttpFrameOfTheSameDomainForAnotherSite() {
        val code = Node("code", htmlTag = "input", htmlAttributes = mapOf("autocomplete" to "one-time-code"))
        val frame = Node(isText = false, webDomain = "github.com", webScheme = "http", children = listOf(code.copy(id = "framed")))
        val found = find(code, frame, webDomain = "github.com", webScheme = "https")
        assertEquals(listOf(CodeField("code", null)), found.fields)
        assertEquals("https", found.webScheme)
    }

    @Test
    fun putsACharacterInEachBoxTheHintsNumber() {
        val boxes = (6 downTo 1).map { Node("box$it", autofillHints = listOf("smsOTPCode$it"), maxLength = 1) }
        val found = find(*boxes.toTypedArray())
        assertEquals((1..6).map { CodeField("box$it", it - 1) }, found.fields)
    }

    @Test
    fun putsACharacterInEachOfARowOfOneCharacterBoxes() {
        val boxes = (1..6).map { Node("box$it", idEntry = "otp_digit_$it", inputType = NUMBER, maxLength = 1) }
        val found = find(*boxes.toTypedArray())
        assertEquals((1..6).map { CodeField("box$it", it - 1) }, found.fields)
    }

    @Test
    fun guessesAShortNumericFieldThatSaysItWantsACode() {
        for (id in listOf("verification_code", "otp", "twoFactorCode", "mfa_token", "code")) {
            val found = find(Node("pw", inputType = TEXT_PASSWORD, idEntry = "password"), Node("code", idEntry = id, inputType = NUMBER))
            assertEquals(id, listOf(CodeField("code", null)), found.fields)
        }
        val french = find(Node("code", hint = "Code de vérification", inputType = NUMBER))
        assertEquals(listOf(CodeField("code", null)), french.fields)
    }

    @Test
    fun leavesOtherCodesAlone() {
        for (id in listOf("zip_code", "postal_code", "promo_code", "coupon_code", "country_code", "phone", "captcha_code", "card_security_code")) {
            assertEquals(id, emptyList<CodeField<String>>(), find(Node("f", idEntry = id, inputType = NUMBER)).fields)
        }
    }

    @Test
    fun leavesPasswordsEmailsAndLongTextFieldsAlone() {
        assertEquals(emptyList<CodeField<String>>(), find(Node("f", idEntry = "verification_code", inputType = TEXT_PASSWORD)).fields)
        assertEquals(emptyList<CodeField<String>>(), find(Node("f", idEntry = "code", inputType = TEXT_EMAIL)).fields)
        assertEquals(emptyList<CodeField<String>>(), find(Node("f", idEntry = "code", inputType = TEXT)).fields)
        assertEquals(emptyList<CodeField<String>>(), find(Node("f", htmlTag = "input", htmlAttributes = mapOf("type" to "password", "name" to "otp"))).fields)
    }

    @Test
    fun leavesHiddenAndUnfillableFieldsAlone() {
        assertEquals(emptyList<CodeField<String>>(), find(Node("f", autofillHints = listOf("smsOTPCode"), visible = false)).fields)
        assertEquals(emptyList<CodeField<String>>(), find(Node("f", autofillHints = listOf("smsOTPCode"), isText = false)).fields)
        assertEquals(emptyList<CodeField<String>>(), find(Node(null, autofillHints = listOf("smsOTPCode"))).fields)
    }

    @Test
    fun prefersAFieldTheHintsNameOverAGuess() {
        val found = find(Node("guess", idEntry = "code", inputType = NUMBER), Node("hinted", autofillHints = listOf("2faAppOTPCode")))
        assertEquals(listOf(CodeField("hinted", null)), found.fields)
    }

    @Test
    fun fillsTheFieldAPersonAsksToAutofillFromItsMenu() {
        val nickname = Node("nick", idEntry = "nickname", focused = true)
        assertEquals(listOf(CodeField("nick", null)), find(Node("other", idEntry = "city"), nickname, manual = true).fields)
        assertEquals(nothing, find(Node("other", idEntry = "city"), nickname).fields)
        // A code field on the screen is still the one filled
        val code = Node("code", autofillHints = listOf("smsOTPCode"))
        assertEquals(listOf(CodeField("code", null)), find(nickname, code, manual = true).fields)
        // Nothing focused, or a field that takes no text: nothing to fill
        assertEquals(nothing, find(Node("other", idEntry = "city"), manual = true).fields)
        assertEquals(nothing, find(Node("box", focused = true, isText = false), manual = true).fields)
    }

    @Test
    fun takesChromesPredictionThatAFieldWantsACode() {
        fun chrome(vararg attributes: Pair<String, String>) =
            Node("f", htmlTag = "input", htmlAttributes = mapOf("type" to "text", "name" to "q7") + attributes)
        assertEquals(listOf(CodeField("f", null)), find(chrome("computed-autofill-hints" to "ONE_TIME_CODE")).fields)
        assertEquals(listOf(CodeField("f", null)), find(chrome("crowdsourcing-autofill-hints" to "ONE_TIME_CODE")).fields)
        assertEquals(listOf(CodeField("f", null)), find(chrome("crowdsourcing-predictions-autofill-hints" to "NO_SERVER_DATA,ONE_TIME_CODE")).fields)
        assertEquals(nothing, find(chrome("computed-autofill-hints" to "USERNAME", "crowdsourcing-autofill-hints" to "NO_SERVER_DATA")).fields)
    }

    @Test
    fun findsAFieldNamedOtpOrTwoFactorHoweverLongItIs() {
        for (id in listOf("otp", "twoFactorCode", "mfaToken", "OTPCode", "verification_code", "auth-mfa-otpcode", "2fa")) {
            assertEquals(id, listOf(CodeField("f", null)), find(Node("f", idEntry = id)).fields)
        }
        assertEquals(listOf(CodeField("f", null)), find(Node("f", hint = "Code de vérification")).fields)
        val web = Node("f", htmlTag = "input", htmlAttributes = mapOf("type" to "text", "name" to "totp"))
        assertEquals(listOf(CodeField("f", null)), find(web).fields)
    }

    @Test
    fun takesNoWordForOtpThatIsPartOfAnother() {
        assertEquals(nothing, find(Node("f", idEntry = "footprint", inputType = NUMBER, maxLength = 6)).fields)
        assertEquals(nothing, find(Node("f", idEntry = "laptop_tag", inputType = NUMBER)).fields)
    }

    @Test
    fun findsAShortNumericFieldWhoseNameHasTheWordCode() {
        assertEquals(listOf(CodeField("f", null)), find(Node("f", idEntry = "smsCode", inputType = NUMBER)).fields)
        assertEquals(nothing, find(Node("f", idEntry = "smsCode", inputType = TEXT)).fields)
    }

    @Test
    fun leavesRecoveryAndBackupCodeFieldsAlone() {
        for (id in listOf("recovery_code", "backupCode", "otp_recovery", "code_de_secours")) {
            assertEquals(id, nothing, find(Node("f", idEntry = id, inputType = NUMBER, maxLength = 10)).fields)
        }
    }

    @Test
    fun fillsARowOfOneCharacterBoxesThatNamesNoCode() {
        val boxes = (1..6).map { Node("box$it", idEntry = "digit$it", inputType = NUMBER, maxLength = 1) }
        assertEquals((1..6).map { CodeField("box$it", it - 1) }, find(*boxes.toTypedArray()).fields)
        val web = (1..6).map { Node("box$it", htmlTag = "input", htmlAttributes = mapOf("type" to "tel", "maxlength" to "1")) }
        assertEquals((1..6).map { CodeField("box$it", it - 1) }, find(*web.toTypedArray()).fields)
        // Three boxes aren't a code, nor is a row of password boxes
        assertEquals(nothing, find(*boxes.take(3).toTypedArray()).fields)
        val secret = (1..6).map { Node("box$it", inputType = TEXT_PASSWORD, maxLength = 1) }
        assertEquals(nothing, find(*secret.toTypedArray()).fields)
    }

    @Test
    fun readsWhatAFieldTellsScreenReaders() {
        assertEquals(listOf(CodeField("f", null)), find(Node("f", contentDescription = "Verification code", inputType = NUMBER)).fields)
    }

    @Test
    fun matchesAFieldInAFrameByTheFramesOwnSite() {
        val inFrame = Node("code", autofillHints = listOf("smsOTPCode"), focused = true)
        val frame = Node(isText = false, webDomain = "evil.test", children = listOf(inFrame))
        val found = FieldFinder.find(screen(frame, webDomain = "github.com"))
        assertEquals(listOf(CodeField("code", null)), found.fields)
        assertEquals("evil.test", found.webDomain)
    }

    @Test
    fun fillsOnlyTheFieldsOfTheFocusedFieldsSite() {
        // The page's code field is focused: the frame's isn't filled with the page's code
        val page = Node("page", autofillHints = listOf("smsOTPCode"), focused = true)
        val framed = Node("framed", autofillHints = listOf("smsOTPCode"))
        val frame = Node(isText = false, webDomain = "evil.test", children = listOf(framed))
        val onPage = FieldFinder.find(screen(frame, page, webDomain = "github.com"))
        assertEquals(listOf(CodeField("page", null)), onPage.fields)
        assertEquals("github.com", onPage.webDomain)
        // The frame's is focused: it is matched as the frame's site
        val inFrame = FieldFinder.find(screen(Node("page", autofillHints = listOf("smsOTPCode")), Node(isText = false, webDomain = "evil.test", children = listOf(framed.copy(focused = true))), webDomain = "github.com"))
        assertEquals(listOf(CodeField("framed", null)), inFrame.fields)
        assertEquals("evil.test", inFrame.webDomain)
        // Boxes split across two sites aren't one code
        val boxes = (1..6).map { Node("box$it", inputType = NUMBER, maxLength = 1, focused = it == 1) }
        val split = FieldFinder.find(screen(*boxes.take(3).toTypedArray(), Node(isText = false, webDomain = "evil.test", children = boxes.drop(3)), webDomain = "github.com"))
        assertEquals(nothing, split.fields)
    }

    @Test
    fun findsNothingOnALoginScreen() {
        val found = find(Node("user", autofillHints = listOf("username")), Node("pw", autofillHints = listOf("password"), inputType = TEXT_PASSWORD))
        assertEquals(emptyList<CodeField<String>>(), found.fields)
        assertNull(found.webDomain)
    }
}

private const val NUMBER_PASSWORD = 0x12

private fun login(vararg nodes: Node, webDomain: String? = null, webScheme: String? = null) =
    FieldFinder.findLogin(screen(*nodes, webDomain = webDomain, webScheme = webScheme))

private fun <T> LoginFields<T>.ids() = Triple(username, password, newPasswords)

// openspec: add-passwords, task 5.2
class LoginFieldFinderTest {
    private val signIn = Triple("user", "pw", emptyList<String>())

    @Test
    fun findsANativeSignInByTheHintsAppsSet() {
        for (hint in listOf("username", "emailAddress")) {
            val found = login(Node("user", autofillHints = listOf(hint)), Node("pw", autofillHints = listOf("password")))
            assertEquals(hint, signIn, found.ids())
            assertNull(found.webDomain)
            assertEquals(false, found.asksNewPassword)
        }
    }

    @Test
    fun findsANativeSignInByItsInputTypes() {
        assertEquals(signIn, login(Node("user", inputType = TEXT_EMAIL), Node("pw", inputType = TEXT_PASSWORD)).ids())
        assertEquals(signIn, login(Node("user"), Node("pw", inputType = NUMBER_PASSWORD)).ids())
    }

    @Test
    fun takesTheTextFieldNearestBeforeThePasswordAsTheUsername() {
        val found = login(
            Node("search", idEntry = "search_box"),
            Node("name", idEntry = "first_name"),
            Node("user", idEntry = "login"),
            Node("pw", inputType = TEXT_PASSWORD),
        )
        assertEquals(signIn, found.ids())
        // A search box is never the username, nor a code field
        assertEquals(Triple(null, "pw", emptyList<String>()), login(Node("search", hint = "Search"), Node("pw", inputType = TEXT_PASSWORD)).ids())
        val withCode = login(Node("user", autofillHints = listOf("username")), Node("pw", inputType = TEXT_PASSWORD), Node("code", autofillHints = listOf("smsOTPCode")))
        assertEquals(signIn, withCode.ids())
    }

    @Test
    fun findsWebFieldsByTheAutocompleteChromeHandsOverAsHints() {
        val signInPage = login(
            Node("user", htmlTag = "input", autofillHints = listOf("username")),
            Node("pw", htmlTag = "input", autofillHints = listOf("current-password")),
            webDomain = "larkspur.example",
        )
        assertEquals(signIn, signInPage.ids())
        assertEquals("larkspur.example", signInPage.webDomain)

        val signUp = login(
            Node("user", htmlTag = "input", autofillHints = listOf("email")),
            Node("new", htmlTag = "input", autofillHints = listOf("new-password")),
            Node("again", htmlTag = "input", autofillHints = listOf("new-password")),
            webDomain = "larkspur.example",
        )
        assertEquals(Triple("user", null, listOf("new", "again")), signUp.ids())
        assertEquals(true, signUp.asksNewPassword)
    }

    @Test
    fun findsWebFieldsByChromesPredictions() {
        fun predicted(id: String, type: String) = Node(id, htmlTag = "input", htmlAttributes = mapOf("computed-autofill-hints" to type))
        assertEquals(signIn, login(predicted("user", "USERNAME_AND_EMAIL_ADDRESS"), predicted("pw", "PASSWORD")).ids())
        val signUp = login(predicted("user", "EMAIL_ADDRESS"), predicted("new", "ACCOUNT_CREATION_PASSWORD"), predicted("again", "CONFIRMATION_PASSWORD"))
        assertEquals(Triple("user", null, listOf("new", "again")), signUp.ids())
    }

    @Test
    fun findsWebFieldsByTheirHtmlAttributes() {
        val found = login(
            Node("user", htmlTag = "input", htmlAttributes = mapOf("type" to "email", "name" to "email")),
            Node("pw", htmlTag = "input", htmlAttributes = mapOf("type" to "password", "name" to "password")),
            webDomain = "larkspur.example",
        )
        assertEquals(signIn, found.ids())
        assertEquals("larkspur.example", found.webDomain)
    }

    @Test
    fun tellsASignUpFormsPasswordAndItsConfirmation() {
        val english = login(
            Node("user", inputType = TEXT_EMAIL),
            Node("new", inputType = TEXT_PASSWORD, idEntry = "password"),
            Node("again", inputType = TEXT_PASSWORD, idEntry = "confirm_password"),
        )
        assertEquals(Triple("user", null, listOf("new", "again")), english.ids())
        // Two passwords that say nothing are a new one and its confirmation too
        assertEquals(Triple("user", null, listOf("new", "again")), login(Node("user"), Node("new", inputType = TEXT_PASSWORD), Node("again", inputType = TEXT_PASSWORD)).ids())
        val french = login(
            Node("user", hint = "Adresse e-mail", inputType = TEXT_EMAIL),
            Node("new", hint = "Mot de passe", inputType = TEXT_PASSWORD),
            Node("again", hint = "Confirmer le mot de passe", inputType = TEXT_PASSWORD),
        )
        assertEquals(Triple("user", null, listOf("new", "again")), french.ids())
    }

    @Test
    fun tellsAChangeFormsCurrentPasswordFromTheNewOnes() {
        val named = login(
            Node("pw", inputType = TEXT_PASSWORD, idEntry = "current_password"),
            Node("new", inputType = TEXT_PASSWORD, idEntry = "new_password"),
            Node("again", inputType = TEXT_PASSWORD, idEntry = "confirm_new_password"),
        )
        assertEquals(Triple(null, "pw", listOf("new", "again")), named.ids())
        val french = login(
            Node("pw", hint = "Mot de passe actuel", inputType = TEXT_PASSWORD),
            Node("new", hint = "Nouveau mot de passe", inputType = TEXT_PASSWORD),
            Node("again", hint = "Confirmer le nouveau mot de passe", inputType = TEXT_PASSWORD),
        )
        assertEquals(Triple(null, "pw", listOf("new", "again")), french.ids())
        // Three passwords that say nothing: the current one, then the new one and its confirmation
        val bare = login(Node("pw", inputType = TEXT_PASSWORD), Node("new", inputType = TEXT_PASSWORD), Node("again", inputType = TEXT_PASSWORD))
        assertEquals(Triple(null, "pw", listOf("new", "again")), bare.ids())
        // A current password the page names keeps its place beside a confirmation
        val web = login(
            Node("pw", htmlTag = "input", htmlAttributes = mapOf("autocomplete" to "current-password", "type" to "password")),
            Node("again", htmlTag = "input", htmlAttributes = mapOf("type" to "password", "name" to "confirm")),
        )
        assertEquals(Triple(null, "pw", listOf("again")), web.ids())
    }

    @Test
    fun countsAUsernameAloneOnlyWhenTheFieldSaysSo() {
        assertEquals(Triple("user", null, emptyList<String>()), login(Node("user", autofillHints = listOf("emailAddress"))).ids())
        assertEquals(true, login(Node("user", inputType = TEXT_EMAIL)).isEmpty)
        assertEquals(true, login(Node("name", idEntry = "first_name")).isEmpty)
    }

    @Test
    fun findsNoLoginOnACodeScreen() {
        val found = login(Node("code", autofillHints = listOf("smsOTPCode")), Node("box", idEntry = "otp", inputType = NUMBER))
        assertEquals(true, found.isEmpty)
        assertNull(found.webDomain)
    }

    @Test
    fun saysWhatTheFocusedFieldIsFor() {
        fun focusedOn(id: String) = login(
            Node("user", inputType = TEXT_EMAIL, focused = id == "user"),
            Node("new", inputType = TEXT_PASSWORD, focused = id == "new"),
            Node("again", inputType = TEXT_PASSWORD, focused = id == "again"),
            Node("other", idEntry = "nickname", focused = id == "other"),
        ).focused
        assertEquals(LoginRole.USERNAME, focusedOn("user"))
        assertEquals(LoginRole.NEW_PASSWORD, focusedOn("new"))
        assertEquals(LoginRole.NEW_PASSWORD, focusedOn("again"))
        assertNull(focusedOn("other"))
    }

    @Test
    fun takesASignInFormInAFrameFromAnotherSiteAsThatSite() {
        fun page(focus: String?) = screen(
            Node("outer-user", inputType = TEXT_EMAIL, focused = focus == "outer-user"),
            Node("outer-pw", inputType = TEXT_PASSWORD),
            Node(
                isText = false,
                webDomain = "evil.test",
                children = listOf(
                    Node("frame-user", inputType = TEXT_EMAIL, focused = focus == "frame-user"),
                    Node("frame-pw", inputType = TEXT_PASSWORD),
                ),
            ),
            webDomain = "larkspur.example",
        )
        val inFrame = FieldFinder.findLogin(page("frame-user"))
        assertEquals(Triple("frame-user", "frame-pw", emptyList<String>()), inFrame.ids())
        assertEquals("evil.test", inFrame.webDomain)

        val onPage = FieldFinder.findLogin(page("outer-user"))
        assertEquals(Triple("outer-user", "outer-pw", emptyList<String>()), onPage.ids())
        assertEquals("larkspur.example", onPage.webDomain)

        // Nothing focused: the site of the first password
        assertEquals("larkspur.example", FieldFinder.findLogin(page(null)).webDomain)
    }

    @Test
    fun carriesTheSchemeOfTheNodeThatNamesTheLoginsSite() {
        val user = Node("user", inputType = TEXT_EMAIL)
        val pw = Node("pw", inputType = TEXT_PASSWORD)
        assertEquals("https", login(user, pw, webDomain = "larkspur.example", webScheme = "https").webScheme)
        assertEquals("http", login(user, pw, webDomain = "larkspur.example", webScheme = "http").webScheme)
        assertNull(login(user, pw, webDomain = "larkspur.example").webScheme)
        // An http frame of the same domain is a site of its own, over its own scheme
        val frame = Node(
            isText = false,
            webDomain = "larkspur.example",
            webScheme = "http",
            children = listOf(Node("frame-user", inputType = TEXT_EMAIL), Node("frame-pw", inputType = TEXT_PASSWORD, focused = true)),
        )
        val inFrame = login(user, pw, frame, webDomain = "larkspur.example", webScheme = "https")
        assertEquals(Triple("frame-user", "frame-pw", emptyList<String>()), inFrame.ids())
        assertEquals("http", inFrame.webScheme)
        val onPage = login(user.copy(focused = true), pw, frame, webDomain = "larkspur.example", webScheme = "https")
        assertEquals(signIn, onPage.ids())
        assertEquals("https", onPage.webScheme)
    }

    // openspec: add-passwords, task 5.7: what "Suggest a strong password" fills, and for what limits
    @Test
    fun suggestsForTheNewPasswordAndItsConfirmationWithTheirLimits() {
        val signUp = login(
            Node("user", inputType = TEXT_EMAIL),
            Node("new", inputType = TEXT_PASSWORD, idEntry = "password", maxLength = 20, focused = true),
            Node("again", inputType = TEXT_PASSWORD, idEntry = "confirm_password", maxLength = 16),
        )
        assertEquals(listOf("new", "again"), signUp.newPasswords)
        assertEquals(LoginRole.NEW_PASSWORD, signUp.focused)
        // The field that takes fewest characters holds both
        assertEquals(16, signUp.newPasswordMaxLength)
        assertNull(signUp.newPasswordRules)

        val web = login(
            Node("pw", htmlTag = "input", htmlAttributes = mapOf("type" to "password", "autocomplete" to "current-password")),
            Node(
                "new",
                htmlTag = "input",
                htmlAttributes = mapOf("type" to "password", "autocomplete" to "new-password", "maxlength" to "32", "passwordrules" to "minlength: 10; required: digit;"),
            ),
            webDomain = "larkspur.example",
        )
        assertEquals(Triple(null, "pw", listOf("new")), web.ids())
        assertEquals(32, web.newPasswordMaxLength)
        assertEquals("minlength: 10; required: digit;", web.newPasswordRules)
        // A sign-in form asks for no new password
        assertEquals(false, login(Node("user"), Node("pw", inputType = TEXT_PASSWORD)).asksNewPassword)
    }
}

// openspec: add-passwords, task 5.8: what a sent form saves, from the structure as it was sent
class SaveDecisionTest {
    private val larkspur = Target.web("larkspur.example")
    private val bank = Target.App("com.bank.app", "aa11")
    private val vaultLogins = listOf(
        LoginEntry("personal", "mail", "Larkspur Mail", "Ada@Example.org", listOf("larkspur.example")),
        LoginEntry("work", "work-mail", "Larkspur Mail", "ada@example.org", listOf("larkspur.example")),
        LoginEntry("personal", "bank", "Banking app", "ada", emptyList()),
    )
    private val bankPick = listOf(Pick("personal", bank, "bank"))

    private fun sent(username: String?, password: String?, newPassword: String? = null, again: String? = newPassword) = screen(
        Node("user", inputType = TEXT_EMAIL, value = username),
        Node("pw", inputType = TEXT_PASSWORD, value = password),
        Node("new", inputType = TEXT_PASSWORD, value = newPassword),
        Node("again", inputType = TEXT_PASSWORD, value = again),
    )

    private fun decide(
        roots: List<FieldNode<String>>,
        fields: SaveFields<String> = SaveFields("user", "pw", emptyList()),
        target: Target = larkspur,
        vault: String = "personal",
        picks: List<Pick> = emptyList(),
        generated: Set<String> = emptySet(),
    ) = SaveDecision.decide(roots, fields, target, vault, vaultLogins, picks, "Banking", 1795300000000, { it in generated }, { "new-id" })

    @Test
    fun savesANewLoginNamedAfterTheSite() {
        val result = decide(sent("grace@example.org", "hunter2"), target = Target.web("www.larkspur.example"))!!
        assertEquals(false, result.update)
        val record = result.record
        assertEquals("new-id", record.id)
        assertEquals("larkspur.example", record.name)
        assertEquals("grace@example.org", record.username)
        assertEquals("hunter2", record.password)
        assertEquals("www.larkspur.example", record.site)
        assertNull(record.app)
        assertEquals(1795300000000, record.at)
    }

    @Test
    fun updatesTheLoginOfTheSameSiteAndUsernameInTheVaultThePromptNamed() {
        // Personal holds Ada's login: the new password updates it, by its id
        val personal = decide(sent(" ada@example.org ", "new-password"))!!
        assertEquals(true, personal.update)
        assertEquals("mail", personal.record.id)
        assertEquals("Larkspur Mail", personal.record.name)
        assertEquals("ada@example.org", personal.record.username)
        // Work holds one of its own, which Work's prompt updates
        assertEquals("work-mail", decide(sent("ada@example.org", "x"), vault = "work")!!.record.id)
        // A vault with no login there adds one
        assertEquals(false, decide(sent("ada@example.org", "x"), vault = "family")!!.update)
    }

    @Test
    fun savesTheNewPasswordOfASignUpOrChangeForm() {
        val change = decide(sent("ada@example.org", "old", "brand-new"), SaveFields("user", "pw", listOf("new", "again")), generated = setOf("brand-new"))!!
        assertEquals("brand-new", change.record.password)
        assertEquals(true, change.record.generated)
        assertEquals(true, change.update)
        val signUp = decide(sent("grace@example.org", null, "first"), SaveFields("user", null, listOf("new", "again")))!!
        assertEquals("first", signUp.record.password)
        assertEquals(false, signUp.record.generated)
    }

    @Test
    fun savesNothingWithoutAPassword() {
        assertNull(decide(sent("ada@example.org", "")))
        assertNull(decide(sent("ada@example.org", null)))
    }

    @Test
    fun namesALoginSavedInAnAppAfterTheAppWithNoWebsite() {
        val result = decide(sent("grace", "1234"), target = bank)!!
        assertEquals(false, result.update)
        assertEquals("Banking", result.record.name)
        assertNull(result.record.site)
        assertEquals(InboxApp("com.bank.app", "aa11"), result.record.app)
        // The login picked in the app is updated there
        val again = decide(sent("ADA", "5678"), target = bank, picks = bankPick)!!
        assertEquals(true, again.update)
        assertEquals("bank", again.record.id)
    }

    @Test
    fun knowsTheUsernamesAPromptUpdates() {
        assertEquals(listOf("Ada@Example.org"), SaveDecision.knownUsernames(larkspur, "personal", vaultLogins, emptyList()))
        assertEquals(emptyList<String>(), SaveDecision.knownUsernames(bank, "personal", vaultLogins, emptyList()))
        assertEquals(listOf("ada"), SaveDecision.knownUsernames(bank, "personal", vaultLogins, bankPick))
    }
}
