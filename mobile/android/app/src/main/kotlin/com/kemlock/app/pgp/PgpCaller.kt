package com.kemlock.app.pgp

import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import java.security.MessageDigest

/**
 * How an app is signed, as the package manager says, free of Android's types so the JVM tests
 * make their own: the SHA-256 of each certificate it is signed with now and, with one signer,
 * of each certificate of its rotation lineage, the original first.
 */
class PgpSigning(val signers: List<ByteArray>, val lineage: List<ByteArray>, val multipleSigners: Boolean)

/**
 * The app asking the mail provider (openspec: add-pgp-mail-provider, decision 4): the package of
 * the binder's uid, pinned to the SHA-256 of the first certificate of its signing lineage, which
 * a key rotation keeps. A caller that cannot be pinned is refused: the service answers it with an
 * error before Dart is asked, the same whether the vault is open or locked.
 */
sealed class PgpCaller {
    abstract val packageName: String

    data class Pinned(override val packageName: String, val cert: String, val label: String?) : PgpCaller()

    data class Refused(override val packageName: String, val reason: String, val label: String? = null) : PgpCaller()

    /** What the channel `com.kemlock.app/mail` carries (lib/features/mail/mail_caller.dart). */
    fun toMap(): Map<String, Any?> = when (this) {
        is Pinned -> mapOf("package" to packageName, "cert" to cert, "label" to label)
        is Refused -> mapOf("package" to packageName, "cert" to "", "label" to label, "refused" to reason)
    }

    companion object {
        const val SEVERAL_SIGNERS = "severalSigners"
        const val NO_PACKAGE = "noPackage"
        const val ITSELF = "itself"

        /**
         * The caller with [packages] for its uid, [signing] read for its package and [label] its
         * name. Several signers, no package (or several, a shared uid) and Kemlock itself
         * ([ownPackage]) are refused.
         */
        fun of(packages: List<String>, ownPackage: String, signing: (String) -> PgpSigning?, label: (String) -> String?): PgpCaller {
            val packageName = packages.singleOrNull() ?: return Refused(packages.firstOrNull().orEmpty(), NO_PACKAGE)
            if (packageName == ownPackage) return Refused(packageName, ITSELF)
            val signed = signing(packageName) ?: return Refused(packageName, NO_PACKAGE)
            if (signed.multipleSigners || signed.signers.size > 1) return Refused(packageName, SEVERAL_SIGNERS, label(packageName))
            val original = signed.lineage.firstOrNull() ?: signed.signers.firstOrNull() ?: return Refused(packageName, NO_PACKAGE)
            return Pinned(packageName, hex(original), label(packageName))
        }

        fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

        /** The caller of the binder call under way, read from the package manager. */
        fun read(context: Context, uid: Int): PgpCaller {
            val pm = context.packageManager
            return of(
                packages = pm.getPackagesForUid(uid)?.toList().orEmpty(),
                ownPackage = context.packageName,
                signing = { signingOf(pm, it) },
                label = { name ->
                    try {
                        pm.getApplicationLabel(pm.getApplicationInfo(name, 0)).toString()
                    } catch (_: PackageManager.NameNotFoundException) {
                        null
                    }
                },
            )
        }

        private fun signingOf(pm: PackageManager, packageName: String): PgpSigning? = try {
            fun digest(signature: Signature) = MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES).signingInfo?.let { info ->
                    val multiple = info.hasMultipleSigners()
                    val lineage = if (multiple) emptyList() else info.signingCertificateHistory.orEmpty().map(::digest)
                    PgpSigning(info.apkContentsSigners.orEmpty().map(::digest), lineage, multiple)
                }
            } else {
                @Suppress("DEPRECATION")
                val signers = pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES).signatures.orEmpty().map(::digest)
                PgpSigning(signers, if (signers.size == 1) signers else emptyList(), signers.size > 1)
            }
        } catch (_: PackageManager.NameNotFoundException) {
            null
        }
    }
}
