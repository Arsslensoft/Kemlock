package com.kemlock.app.passkeys

/**
 * JSON written the way Dart's `jsonEncode` writes it, so a file sealed here holds the bytes the
 * app's would (`test/fixtures/passkeys` pins them): maps in their order, no spaces, `"` and `\`
 * escaped, control characters as `\b`, `\t`, `\n`, `\f`, `\r` or `\u00xx`, lone surrogates as
 * `\udxxx`, and everything else, `/` included, as it is. android's org.json writes `/` as `\/`,
 * which reads the same but isn't the same bytes. A map entry whose value is null is left out, as
 * Dart's `'key': ?value` leaves it.
 */
object Json {
    fun write(value: Any?): String = StringBuilder().also { append(it, value) }.toString()

    private fun append(out: StringBuilder, value: Any?) {
        when (value) {
            null -> out.append("null")
            is String -> string(out, value)
            is Boolean -> out.append(value)
            is Int, is Long, is Short, is Byte -> out.append(value)
            is Map<*, *> -> {
                out.append('{')
                var first = true
                for ((key, item) in value) {
                    if (item == null) continue
                    if (!first) out.append(',')
                    first = false
                    string(out, key as String)
                    out.append(':')
                    append(out, item)
                }
                out.append('}')
            }
            is Iterable<*> -> {
                out.append('[')
                value.forEachIndexed { i, item ->
                    if (i > 0) out.append(',')
                    append(out, item)
                }
                out.append(']')
            }
            else -> throw IllegalArgumentException("No JSON for ${value::class.java.simpleName}")
        }
    }

    private fun string(out: StringBuilder, s: String) {
        out.append('"')
        for (i in s.indices) {
            val c = s[i]
            when {
                c == '"' || c == '\\' -> out.append('\\').append(c)
                c < ' ' -> out.append(
                    when (c) {
                        '\b' -> "\\b"
                        '\t' -> "\\t"
                        '\n' -> "\\n"
                        '\u000c' -> "\\f"
                        '\r' -> "\\r"
                        else -> "\\u00" + hex(c.code shr 4) + hex(c.code)
                    },
                )
                c.isHighSurrogate() && !(i + 1 < s.length && s[i + 1].isLowSurrogate()) -> escape(out, c)
                c.isLowSurrogate() && !(i > 0 && s[i - 1].isHighSurrogate()) -> escape(out, c)
                else -> out.append(c)
            }
        }
        out.append('"')
    }

    private fun escape(out: StringBuilder, c: Char) {
        out.append("\\u")
        for (shift in intArrayOf(12, 8, 4, 0)) out.append(hex(c.code shr shift))
    }

    private fun hex(value: Int): Char = "0123456789abcdef"[value and 0xf]
}
