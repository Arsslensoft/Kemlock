package com.kemlock.app.platformpasskey

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlatformPasskeyTest {
    @Test
    fun credentialManagerIsOfferedFromAndroid14() {
        assertFalse(PlatformPasskey.supported(33))
        assertTrue(PlatformPasskey.supported(34))
        assertTrue(PlatformPasskey.supported(36))
    }

    @Test
    fun theUserClosingThePickerIsACancel() {
        assertEquals("cancelled", PlatformPasskey.errorCode(PlatformPasskey.TYPE_USER_CANCELED))
    }

    @Test
    fun noPasskeyForTheAccountIsSaidSo() {
        assertEquals("noCredential", PlatformPasskey.errorCode(PlatformPasskey.TYPE_NO_CREDENTIAL))
    }

    @Test
    fun anythingElseIsAFailureAndNeverACancel() {
        assertEquals("failed", PlatformPasskey.errorCode("android.credentials.GetCredentialException.TYPE_UNKNOWN"))
        assertEquals("failed", PlatformPasskey.errorCode(null))
    }

    @Test
    fun theBundleKeysAreTheOnesAndroidxCredentialsWrites() {
        assertEquals("androidx.credentials.TYPE_PUBLIC_KEY_CREDENTIAL", PlatformPasskey.TYPE_PUBLIC_KEY)
        assertEquals("androidx.credentials.BUNDLE_KEY_REQUEST_JSON", PlatformPasskey.KEY_REQUEST_JSON)
        assertEquals("androidx.credentials.BUNDLE_KEY_AUTHENTICATION_RESPONSE_JSON", PlatformPasskey.KEY_RESPONSE_JSON)
    }

    // The request Dart's `platformPasskeyRequest` writes for a server's passkey options (km_platform_passkey.dart)
    private val request = """
        {"challenge":"Y2hhbGxlbmdl","rpId":"kem.example.com","timeout":60000,"userVerification":"preferred",
         "allowCredentials":[],"extensions":{"prf":{"eval":{"first":"c2FsdA"}}}}
    """.trimIndent()

    @Test
    fun theRequestDartBuildsIsTaken() {
        assertNull(PlatformPasskey.requestProblem(request))
    }

    @Test
    fun aRequestThatIsNotJsonIsRefused() {
        assertNotNull(PlatformPasskey.requestProblem("not json"))
        assertNotNull(PlatformPasskey.requestProblem("[1]"))
    }

    @Test
    fun aRequestWithNoChallengeOrNoRelyingPartyIsRefused() {
        assertNotNull(PlatformPasskey.requestProblem(request.replace("\"challenge\":\"Y2hhbGxlbmdl\",", "")))
        assertNotNull(PlatformPasskey.requestProblem(request.replace("\"rpId\":\"kem.example.com\",", "")))
    }

    @Test
    fun aRequestThatDoesNotAskForThePrfOutputIsRefused() {
        assertNotNull(PlatformPasskey.requestProblem(request.replace("\"extensions\":{\"prf\":{\"eval\":{\"first\":\"c2FsdA\"}}}", "\"extensions\":{}")))
        assertNotNull(PlatformPasskey.requestProblem(request.replace("\"first\":\"c2FsdA\"", "\"first\":\"\"")))
    }

    @Test
    fun theBundleCarriesTheRequestVerbatimAsAGetOptionThatShowsThePicker() {
        val data = PlatformPasskey.requestData(request)

        assertEquals(request, data[PlatformPasskey.KEY_REQUEST_JSON])
        assertEquals(PlatformPasskey.VALUE_SUBTYPE_GET, data[PlatformPasskey.KEY_SUBTYPE])
        assertEquals(false, data[PlatformPasskey.KEY_PREFER_IMMEDIATE])
        assertEquals(3, data.size)
    }
}
