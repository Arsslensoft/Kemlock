package com.kemlock.credential_transfer

import androidx.credentials.providerevents.exception.ImportCredentialsCancellationException
import androidx.credentials.providerevents.exception.ImportCredentialsInvalidJsonException
import androidx.credentials.providerevents.exception.ImportCredentialsNoExportOptionException
import androidx.credentials.providerevents.exception.ImportCredentialsProviderConfigurationException
import androidx.credentials.providerevents.exception.ImportCredentialsSystemErrorException
import androidx.credentials.providerevents.exception.ImportCredentialsUnknownCallerException
import androidx.credentials.providerevents.exception.ImportCredentialsUnknownErrorException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** What each of the library's import exceptions is told to Dart as (task 5.4). */
class ImportFailureTest {
    @Test
    fun aCancelIsNoFailure() {
        assertNull(ImportFailure.codeOf(ImportCredentialsCancellationException("closed")))
    }

    @Test
    fun everyOtherKindHasItsOwnCode() {
        assertEquals("noExportOption", ImportFailure.codeOf(ImportCredentialsNoExportOptionException("none")))
        assertEquals("unavailable", ImportFailure.codeOf(ImportCredentialsProviderConfigurationException("no play services")))
        assertEquals("invalidJson", ImportFailure.codeOf(ImportCredentialsInvalidJsonException("bad")))
        assertEquals("system", ImportFailure.codeOf(ImportCredentialsSystemErrorException("binder")))
        assertEquals("unknownCaller", ImportFailure.codeOf(ImportCredentialsUnknownCallerException("who")))
        assertEquals("unknown", ImportFailure.codeOf(ImportCredentialsUnknownErrorException("other")))
    }

    @Test
    fun theCodesAreTheOnesDartReads() {
        // lib/credential_transfer.dart's TransferErrorCodes
        assertEquals("busy", ImportFailure.BUSY)
        assertEquals("noActivity", ImportFailure.NO_ACTIVITY)
        assertEquals("badRequest", ImportFailure.BAD_REQUEST)
    }
}
