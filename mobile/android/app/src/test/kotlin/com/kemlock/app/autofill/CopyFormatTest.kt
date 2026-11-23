package com.kemlock.app.autofill

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CopyFormatTest {
    private val copy = """
        {"v":1,"vault":"main","accounts":[
          {"id":"a1","issuer":"GitHub","label":"alice","kind":"totp","algorithm":"SHA1","digits":6,"period":30,
           "key":"SGVsbG8h3q2+7w==","domains":["github.com"]},
          {"id":"s1","issuer":"Steam","label":"gaben","kind":"steam","algorithm":"SHA1","digits":5,"period":30,"key":"AQID","domains":[]},
          {"id":"x1","issuer":"Later","label":"","kind":"something-new","algorithm":"SHA1","digits":6,"period":30,"key":"AQID","domains":[]}
        ]}
    """.trimIndent()

    @Test
    fun readsTheCopyTheAppWrites() {
        val accounts = CopyFormat.parseCopy(copy)
        assertEquals(listOf("a1", "s1"), accounts.map { it.id })
        val github = accounts.first()
        assertEquals("main", github.vault)
        assertEquals(Kind.TOTP, github.kind)
        assertEquals(listOf("github.com"), github.domains)
        assertArrayEquals(java.util.Base64.getDecoder().decode("SGVsbG8h3q2+7w=="), github.key)
        assertEquals(Kind.STEAM, accounts[1].kind)
    }

    @Test(expected = UnsupportedFormatException::class)
    fun refusesACopyOfAnotherVersion() {
        CopyFormat.parseCopy(copy.replace("\"v\":1", "\"v\":2"))
    }

    @Test
    fun aCopyForPasskeysAloneFillsNoCodes() {
        assertTrue(CopyFormat.fillsCodes(copy))
        assertFalse(CopyFormat.fillsCodes("""{"v":1,"vault":"main","accounts":[],"passkeys":[{"credentialId":"AA","rpId":"github.com","userHandle":"dQ","userName":"me","privateKey":"AA"}]}"""))
        // Accounts this version can't fill are none to offer either
        assertFalse(CopyFormat.fillsCodes(copy.replace("\"totp\"", "\"hotp\"").replace("\"steam\"", "\"hotp\"")))
        // A copy of another version still offers the fill screen, which says to open the app
        assertTrue(CopyFormat.fillsCodes(copy.replace("\"v\":1", "\"v\":2")))
    }

    @Test
    fun anIndexForPasskeysAloneNamesNoAccounts() {
        assertTrue(CopyFormat.namesAccounts("""{"v":1,"vault":"ab12","accounts":[{"id":"a1","issuer":"GitHub","domains":[]}]}"""))
        assertFalse(CopyFormat.namesAccounts("""{"v":1,"vault":"ab12","accounts":[],"passkeys":[{"credentialId":"AA","rpId":"github.com","userHandle":"dQ","userName":"me"}]}"""))
        assertFalse(CopyFormat.namesAccounts("""{"v":2,"vault":"ab12","accounts":[{"id":"a1","issuer":"GitHub","domains":[]}]}"""))
    }

    @Test
    fun readsTheIndex() {
        val index = CopyFormat.parseIndex("""{"v":1,"vault":"ab12","accounts":[{"id":"a1","issuer":"GitHub","domains":["github.com","=okta.com"]}]}""")
        assertEquals(listOf(IndexAccount("ab12", "a1", "GitHub", listOf("github.com", "=okta.com"))), index)
    }

    @Test(expected = UnsupportedFormatException::class)
    fun refusesAnIndexOfAnotherVersion() {
        CopyFormat.parseIndex("""{"vault":"ab12","accounts":[]}""")
    }

    @Test
    fun readsThePasskeysOfACopyAndAnIndex() {
        val copy = """{"v":1,"vault":"ab12","accounts":[],"passkeys":[
            {"credentialId":"AAECAw","rpId":"webauthn.io","rpName":"WebAuthn.io","userHandle":"dQ","userName":"alice","userDisplayName":"Alice","privateKey":"MIGH"},
            {"credentialId":"BAUG","rpId":"github.com","userHandle":"dg","userName":"bob","privateKey":"MIGI"},
            {"rpId":"broken.example","userHandle":"dg","userName":"no id"}]}"""
        val passkeys = CopyFormat.parsePasskeys(copy)
        assertEquals(listOf("AAECAw", "BAUG"), passkeys.map { it.credentialId })
        val first = passkeys.first()
        assertEquals("ab12", first.vault)
        assertEquals("WebAuthn.io", first.rpName)
        assertEquals("Alice", first.userDisplayName)
        assertEquals("MIGH", first.privateKey)
        assertNull(passkeys[1].rpName)
        assertNull(passkeys[1].userDisplayName)
        // The index has the same entries without keys, and the accounts read as before
        val index = CopyFormat.parsePasskeys(copy.replace(""","privateKey":"MIGH"""", "").replace(""","privateKey":"MIGI"""", ""))
        assertEquals(listOf(null, null), index.map { it.privateKey })
        assertEquals(emptyList<CopyAccount>(), CopyFormat.parseCopy(copy))
        assertEquals(emptyList<IndexAccount>(), CopyFormat.parseIndex(copy))
        // Every copy before passkeys holds none
        assertEquals(emptyList<PasskeyEntry>(), CopyFormat.parsePasskeys(this.copy))
        assertEquals("alice", first.name)
        assertEquals(false, first.toString().contains("MIGH"))
    }

    @Test(expected = UnsupportedFormatException::class)
    fun refusesPasskeysOfAnotherVersion() {
        CopyFormat.parsePasskeys("""{"v":2,"vault":"ab12","accounts":[],"passkeys":[]}""")
    }

    // openspec: add-passwords, task 5.4: the copy and index as AutofillLogin writes them
    private val loginsCopy = """{"v":1,"vault":"ab12","accounts":[],"logins":[
        {"id":"l1","name":"Larkspur Mail","username":"ada@example.org","password":"hunter2","domains":["larkspur.example","=10.0.0.1"]},
        {"id":"l2","name":"Banking app","password":"1234","domains":[]},
        {"name":"no id","password":"x","domains":[]},
        {"id":"l4","name":"no domains","password":"x"}]}"""

    @Test
    fun readsTheLoginsOfACopyAndAnIndex() {
        val logins = CopyFormat.parseLogins(loginsCopy)
        // An entry without its id or domains is left out, not the copy
        assertEquals(listOf("l1", "l2"), logins.map { it.id })
        val mail = logins.first()
        assertEquals("ab12", mail.vault)
        assertEquals("Larkspur Mail", mail.name)
        assertEquals("ada@example.org", mail.username)
        assertEquals("hunter2", mail.password)
        assertEquals(listOf("larkspur.example", "=10.0.0.1"), mail.domains)
        assertNull(logins[1].username)
        assertEquals(emptyList<String>(), logins[1].domains)
        assertFalse(mail.toString().contains("hunter2"))
        // The index holds them without passwords
        val index = CopyFormat.parseLogins(loginsCopy.replace(""","password":"hunter2"""", "").replace(""","password":"1234"""", ""))
        assertEquals(listOf(null, null), index.map { it.password })
        assertTrue(CopyFormat.holdsLogins(loginsCopy))
    }

    @Test
    fun aCopyForLoginsAloneFillsNoCodesAndNamesNoAccounts() {
        assertFalse(CopyFormat.fillsCodes(loginsCopy))
        assertFalse(CopyFormat.namesAccounts(loginsCopy))
        assertEquals(emptyList<PasskeyEntry>(), CopyFormat.parsePasskeys(loginsCopy))
    }

    @Test
    fun aCopyFromBeforePasswordsHoldsNoLogins() {
        assertEquals(emptyList<LoginEntry>(), CopyFormat.parseLogins(copy))
        assertFalse(CopyFormat.holdsLogins(copy))
        assertFalse(CopyFormat.holdsLogins(loginsCopy.replace("\"v\":1", "\"v\":2")))
    }

    @Test(expected = UnsupportedFormatException::class)
    fun refusesLoginsOfAnotherVersion() {
        CopyFormat.parseLogins(loginsCopy.replace("\"v\":1", "\"v\":2"))
    }

    @Test
    fun keepsWhatAVaultTakes() {
        val takes = VaultTakes(passkeys = true, logins = false, suggest = true)
        assertEquals(takes, VaultTakes.parse(takes.toJson()))
        assertNull(VaultTakes.parse(takes.toJson().replace("\"v\":1", "\"v\":2")))
        assertNull(VaultTakes.parse("not json"))
        // As the channel hands them over; an app from before passwords sends none
        assertEquals(VaultTakes(logins = true, suggest = true), VaultTakes.fromMap(mapOf("passkeys" to false, "logins" to true, "suggest" to true)))
        assertNull(VaultTakes.fromMap(null))
    }

    @Test
    fun writesAndReadsPicks() {
        val picks = listOf(Pick("v1", Target.web("github.com"), "a1"), Pick("v1", Target.App("com.bank.app", "aa11"), "b1"))
        assertEquals(picks, CopyFormat.parsePlainPicks("v1", CopyFormat.plainPicks(picks)))
        assertEquals(picks[1], Pick.parse("v1", picks[1].toJson()))
        assertNull(Pick.parse("v1", """{"v":2,"target":"web:github.com","account":"a1"}"""))
        assertNull(Pick.parse("v1", """{"v":1,"target":"ftp:github.com","account":"a1"}"""))
        assertNull(Pick.parse("v1", "not json"))
    }

    @Test
    fun readsTargetsBack() {
        assertEquals(Target.Web("github.com"), Target.parse("web:github.com"))
        assertEquals(Target.App("com.example.app", "abcd"), Target.parse("app:com.example.app:abcd"))
        assertNull(Target.parse("web:"))
        assertNull(Target.parse("app:com.example.app"))
        assertEquals(Target.Web("github.com"), Target.web("GitHub.com."))
    }
}
