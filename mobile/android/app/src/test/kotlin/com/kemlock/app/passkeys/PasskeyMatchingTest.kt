package com.kemlock.app.passkeys

import com.kemlock.app.autofill.CopyFormat
import com.kemlock.app.autofill.PasskeyEntry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PasskeyMatchingTest {
    private fun id(vararg bytes: Int) = B64.url(ByteArray(bytes.size) { bytes[it].toByte() })

    private fun passkey(vault: String, credentialId: String, rpId: String, userName: String) =
        PasskeyEntry(vault, credentialId, rpId, null, "dQ", userName, null)

    // Two vaults' indexes, and a passkey the provider made that the app has since taken in
    private val held = listOf(
        passkey("main", id(1), "github.com", "alice"),
        passkey("main", id(2), "github.com", "alice-work"),
        passkey("main", id(3), "login.example.com", "bob"),
        passkey("ab12", id(4), "example.com", "carol"),
        passkey("ab12", id(1), "github.com", "alice"),
        passkey("ab12", "not base64url!", "github.com", "broken"),
    )

    private fun matching(rpId: String, vararg allowed: String) =
        PasskeyMatching.matching(rpId, allowed.map { B64.fromUrl(it) }, held).map { it.userName }

    @Test
    fun offersEveryAccountOfTheSite() {
        assertEquals(listOf("alice", "alice-work"), matching("github.com"))
        assertEquals(listOf("alice", "alice-work"), matching("GitHub.com."))
    }

    @Test
    fun offersNothingForAnotherSiteEvenASubdomainOrParent() {
        assertEquals(emptyList<String>(), matching("gist.github.com"))
        assertEquals(emptyList<String>(), matching("evilgithub.com"))
        assertEquals(emptyList<String>(), matching("github.com.evil.io"))
        assertEquals(listOf("carol"), matching("example.com"))
        assertEquals(listOf("bob"), matching("login.example.com"))
        assertEquals(emptyList<String>(), matching("other.example.com"))
    }

    @Test
    fun offersOnlyTheCredentialsTheRequestAllows() {
        assertEquals(listOf("alice-work"), matching("github.com", id(2)))
        assertEquals(listOf("alice", "alice-work"), matching("github.com", id(2), id(1)))
        assertEquals(emptyList<String>(), matching("github.com", id(4)))
        // Padding or not, the id is the same
        assertEquals(listOf("alice-work"), matching("github.com", id(2) + "=="))
    }

    @Test
    fun offersEachCredentialOnce() {
        assertEquals(listOf("main", "main"), PasskeyMatching.matching("github.com", emptyList(), held).map { it.vault })
    }

    @Test
    fun matchesWhatTheIndexHolds() {
        val index = CopyFormat.parsePasskeys(
            """{"v":1,"vault":"ab12","accounts":[],"passkeys":[
                {"credentialId":"${id(9, 9)}","rpId":"webauthn.io","userHandle":"dQ","userName":"","userDisplayName":"Dee"},
                {"credentialId":"${id(8)}","rpId":"webauthn.io","userHandle":"dQ","userName":"eve"}]}""",
        )
        val offered = PasskeyMatching.matching("webauthn.io", listOf(byteArrayOf(9, 9)), index)
        assertEquals(1, offered.size)
        assertEquals("Dee", offered.single().name)
        assertNull(offered.single().privateKey)
    }

    @Test
    fun offersTheVaultUsedLastFirst() {
        val written = mapOf("main" to 100L, "ab12" to 300L, "cd34" to 200L)
        assertEquals(listOf("ab12", "cd34", "main", "zz99"), PasskeyMatching.byLastUse(listOf("main", "zz99", "cd34", "ab12"), written::get))
        assertEquals(listOf("a", "b"), PasskeyMatching.byLastUse(listOf("b", "a")) { null })
    }

    @Test
    fun namesAVaultAsTheLockScreenDoes() {
        assertEquals("backmycodes_vault_config", PasskeyMatching.configKey("main"))
        assertEquals("backmycodes_vault_config::ab12cd", PasskeyMatching.configKey("ab12cd"))
        assertEquals("Work", PasskeyMatching.vaultName("""{"name":"Work","kdf":{}}"""))
        assertNull(PasskeyMatching.vaultName("""{"name":"  "}"""))
        assertNull(PasskeyMatching.vaultName("""{"kdf":{}}"""))
        assertNull(PasskeyMatching.vaultName("""{"name":3}"""))
        assertNull(PasskeyMatching.vaultName("not json"))
        assertNull(PasskeyMatching.vaultName(null))
    }
}
