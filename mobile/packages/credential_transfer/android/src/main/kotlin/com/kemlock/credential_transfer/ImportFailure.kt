package com.kemlock.credential_transfer

import androidx.credentials.providerevents.exception.ImportCredentialsCancellationException
import androidx.credentials.providerevents.exception.ImportCredentialsException
import androidx.credentials.providerevents.exception.ImportCredentialsInvalidJsonException
import androidx.credentials.providerevents.exception.ImportCredentialsNoExportOptionException
import androidx.credentials.providerevents.exception.ImportCredentialsProviderConfigurationException
import androidx.credentials.providerevents.exception.ImportCredentialsSystemErrorException
import androidx.credentials.providerevents.exception.ImportCredentialsUnknownCallerException

/**
 * What the library's import exceptions say to Dart (openspec: plan add-credential-exchange, task
 * 5.4). The codes are the ones `TransferErrorCodes` in lib/credential_transfer.dart names; the
 * sheet's messages are chosen from them. A cancel isn't a failure, so it has no code: the person
 * closed the list, and Dart is told with a null answer.
 */
object ImportFailure {
    const val NO_EXPORT_OPTION = "noExportOption"
    const val UNAVAILABLE = "unavailable"
    const val INVALID_JSON = "invalidJson"
    const val SYSTEM = "system"
    const val UNKNOWN_CALLER = "unknownCaller"
    const val UNKNOWN = "unknown"
    const val BUSY = "busy"
    const val NO_ACTIVITY = "noActivity"
    const val BAD_REQUEST = "badRequest"

    /** The code for [error], or null when the person cancelled. */
    fun codeOf(error: ImportCredentialsException): String? = when (error) {
        is ImportCredentialsCancellationException -> null
        is ImportCredentialsNoExportOptionException -> NO_EXPORT_OPTION
        // A ProviderEventsApiProvider wasn't found: no Play services, or one too old
        is ImportCredentialsProviderConfigurationException -> UNAVAILABLE
        is ImportCredentialsInvalidJsonException -> INVALID_JSON
        is ImportCredentialsSystemErrorException -> SYSTEM
        is ImportCredentialsUnknownCallerException -> UNKNOWN_CALLER
        else -> UNKNOWN
    }
}
