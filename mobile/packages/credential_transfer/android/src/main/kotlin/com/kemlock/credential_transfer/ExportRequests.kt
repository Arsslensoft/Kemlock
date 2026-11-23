package com.kemlock.credential_transfer

/** What answers an export request: the exported activity, which writes the reply and ends. */
interface ExportReplier {
    /** Writes [json] to the importer and ends. */
    fun answer(json: String)

    /** Ends with a cancel: nothing is sent. */
    fun refuse()
}

/** A request that passed [ExportCheck], waiting for the person: who asked, for which vault and kinds. */
class PendingExport(
    /** Made for this request; Dart answers with it. Not the entry's secret id. */
    val id: String,
    val vaultId: String,
    /** The package the system says is importing. */
    val packageName: String,
    /** Its name as the phone shows it, or the package name when it has none. */
    val label: String,
    /** The credential types it asked for. */
    val types: Set<String>,
) {
    fun toMap(): Map<String, Any?> = mapOf("id" to id, "vaultId" to vaultId, "package" to packageName, "app" to label, "types" to types.toList())

    /** Never the types' contents; the id is a handle only. */
    override fun toString() = "PendingExport($packageName)"
}

/**
 * The one export request waiting for the person, in memory only (main thread only). A request is
 * never kept past the process or the activity that holds it: if either goes, so does it, and the
 * importer got a cancel. A newer request replaces an older, which is cancelled.
 */
object ExportRequests {
    private var current: Pair<PendingExport, ExportReplier>? = null

    /** Told of each request as it arrives, while Dart listens. */
    var onRequest: ((PendingExport) -> Unit)? = null

    /** Holds [request], cancelling the one held before, and tells Dart. */
    fun open(request: PendingExport, replier: ExportReplier) {
        val before = current
        current = request to replier
        if (before != null && before.second !== replier) before.second.refuse()
        onRequest?.invoke(request)
    }

    /** The request waiting, if any. */
    fun pending(): PendingExport? = current?.first

    /** Gives [json] to the importer of request [id]. False when [id] isn't the one waiting. */
    fun answer(id: String, json: String): Boolean {
        val (request, replier) = current ?: return false
        if (request.id != id) return false
        current = null
        replier.answer(json)
        return true
    }

    /** Cancels request [id]. False when it isn't the one waiting. */
    fun refuse(id: String): Boolean {
        val (request, replier) = current ?: return false
        if (request.id != id) return false
        current = null
        replier.refuse()
        return true
    }

    /** [replier] ended by itself: its request, if it is the one held, is forgotten. */
    fun closed(replier: ExportReplier) {
        if (current?.second === replier) current = null
    }
}
