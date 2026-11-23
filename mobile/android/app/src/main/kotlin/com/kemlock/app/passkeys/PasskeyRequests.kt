package com.kemlock.app.passkeys

import android.os.Build
import androidx.annotation.RequiresApi
import org.json.JSONArray
import org.json.JSONObject

/** A request Kemlock can't read: the site gets an encoding error and nothing is made or signed. */
class BadRequestException(message: String) : Exception(message)

@RequiresApi(Build.VERSION_CODES.O)
private fun JSONObject.urlBytes(key: String): ByteArray {
    val text = optString(key).ifEmpty { throw BadRequestException("No $key") }
    return try {
        B64.fromUrl(text)
    } catch (_: IllegalArgumentException) {
        throw BadRequestException("$key isn't base64url")
    }
}

/** The credential ids of a list of `{"type": "public-key", "id": …}` descriptors; ones that don't decode are left out. */
@RequiresApi(Build.VERSION_CODES.O)
private fun descriptors(list: JSONArray?): List<ByteArray> = (0 until (list?.length() ?: 0)).mapNotNull { i ->
    val d = list!!.optJSONObject(i) ?: return@mapNotNull null
    if (d.optString("type", "public-key") != "public-key") return@mapNotNull null
    try {
        d.urlBytes("id")
    } catch (_: BadRequestException) {
        null
    }
}

/** What a site asks of a new passkey: WebAuthn's `PublicKeyCredentialCreationOptionsJSON`, the part Kemlock reads. */
@RequiresApi(Build.VERSION_CODES.O)
class CreationOptions(
    /** The relying party's id; a browser may leave it to the site's host. */
    val rpId: String?,
    val rpName: String?,
    val userHandle: ByteArray,
    val userName: String,
    val userDisplayName: String?,
    val challenge: ByteArray,
    /** The COSE algorithms the site accepts, in its order; empty means WebAuthn's defaults, ES256 among them. */
    val algorithms: List<Int>,
    /** Credentials the site already has for the account, which Kemlock must not make again. */
    val excluded: List<ByteArray>,
    /** The site asks whether the passkey is discoverable. */
    val credProps: Boolean,
) {
    val acceptsEs256: Boolean get() = algorithms.isEmpty() || PasskeyBytes.ES256 in algorithms

    companion object {
        fun parse(json: String): CreationOptions {
            val o = try {
                JSONObject(json)
            } catch (_: org.json.JSONException) {
                throw BadRequestException("Not JSON")
            }
            val rp = o.optJSONObject("rp") ?: throw BadRequestException("No rp")
            val user = o.optJSONObject("user") ?: throw BadRequestException("No user")
            val params = o.optJSONArray("pubKeyCredParams")
            val algorithms = (0 until (params?.length() ?: 0)).mapNotNull { i ->
                val p = params!!.optJSONObject(i) ?: return@mapNotNull null
                if (p.optString("type", "public-key") != "public-key" || !p.has("alg")) null else p.optInt("alg")
            }
            if (params != null && params.length() > 0 && algorithms.isEmpty()) throw BadRequestException("No public-key algorithm")
            return CreationOptions(
                rpId = rp.optString("id").lowercase().ifEmpty { null },
                rpName = rp.optString("name").ifEmpty { null },
                userHandle = user.urlBytes("id").also { if (it.size > 64) throw BadRequestException("The user handle is over 64 bytes") },
                userName = user.optString("name"),
                userDisplayName = user.optString("displayName").ifEmpty { null },
                challenge = o.urlBytes("challenge"),
                algorithms = algorithms,
                excluded = descriptors(o.optJSONArray("excludeCredentials")),
                credProps = o.optJSONObject("extensions")?.optBoolean("credProps") == true,
            )
        }
    }
}

/** What a site asks to sign in: WebAuthn's `PublicKeyCredentialRequestOptionsJSON`, the part Kemlock reads. */
@RequiresApi(Build.VERSION_CODES.O)
class RequestOptions(
    /** The relying party's id; a browser may leave it to the site's host. */
    val rpId: String?,
    val challenge: ByteArray,
    /** The credentials the site takes; empty means any of the relying party's. */
    val allowed: List<ByteArray>,
) {
    companion object {
        fun parse(json: String): RequestOptions {
            val o = try {
                JSONObject(json)
            } catch (_: org.json.JSONException) {
                throw BadRequestException("Not JSON")
            }
            return RequestOptions(
                rpId = o.optString("rpId").lowercase().ifEmpty { null },
                challenge = o.urlBytes("challenge"),
                allowed = descriptors(o.optJSONArray("allowCredentials")),
            )
        }
    }
}
