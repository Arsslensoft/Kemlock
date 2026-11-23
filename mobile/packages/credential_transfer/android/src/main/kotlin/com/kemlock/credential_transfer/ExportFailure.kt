package com.kemlock.credential_transfer

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas

/**
 * The codes the export half of the plugin answers Dart's calls with when one fails, which
 * `TransferErrorCodes` in lib/credential_transfer.dart names. None carries a message: an error
 * here could sit next to the data it failed to move.
 */
object ExportFailure {
    /** The system refused the entries, or Play services isn't there. */
    const val REGISTER = "registerFailed"

    /** The request being answered is gone: closed, replaced, or the process restarted. */
    const val GONE = "gone"

    const val NO_CONTEXT = "noContext"
    const val BAD_REQUEST = "badRequest"
}

/** Kemlock's launcher icon at the 32 by 32 pixels the selector shows an entry's icon at. */
object ExportIcon {
    private const val SIZE = 32

    fun of(context: Context): Bitmap {
        val drawable = context.packageManager.getApplicationIcon(context.packageName)
        val bitmap = Bitmap.createBitmap(SIZE, SIZE, Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, SIZE, SIZE)
        drawable.draw(Canvas(bitmap))
        return bitmap
    }
}
