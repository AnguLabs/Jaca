package dev.srsouza.jaca.vpn

/// Extracts the SNI host name from a TLS ClientHello, so the phone can tell the desktop
/// proxy which host to mint a certificate for (via HTTP CONNECT). Pure + testable.
object TlsSni {
    fun host(buf: ByteArray, len: Int): String? {
        try {
            if (len < 43 || (buf[0].toInt() and 0xFF) != 0x16) return null  // TLS handshake record
            var p = 5                                                       // skip record header
            if ((buf[p].toInt() and 0xFF) != 0x01) return null             // ClientHello
            p += 4                                                          // handshake type + length
            p += 2                                                          // client_version
            p += 32                                                         // random
            if (p >= len) return null
            p += 1 + (buf[p].toInt() and 0xFF)                             // session_id
            if (p + 2 > len) return null
            p += 2 + (((buf[p].toInt() and 0xFF) shl 8) or (buf[p + 1].toInt() and 0xFF))  // cipher_suites
            if (p >= len) return null
            p += 1 + (buf[p].toInt() and 0xFF)                             // compression_methods
            if (p + 2 > len) return null
            val extEnd = minOf(p + 2 + (((buf[p].toInt() and 0xFF) shl 8) or (buf[p + 1].toInt() and 0xFF)), len)
            p += 2
            while (p + 4 <= extEnd) {
                val type = ((buf[p].toInt() and 0xFF) shl 8) or (buf[p + 1].toInt() and 0xFF)
                val extLen = ((buf[p + 2].toInt() and 0xFF) shl 8) or (buf[p + 3].toInt() and 0xFF)
                p += 4
                if (type == 0x0000) {  // server_name
                    var q = p + 2                                          // skip server_name_list length
                    if (q + 3 > len) return null
                    val nameType = buf[q].toInt() and 0xFF; q += 1
                    val nameLen = ((buf[q].toInt() and 0xFF) shl 8) or (buf[q + 1].toInt() and 0xFF); q += 2
                    if (nameType == 0 && nameLen > 0 && q + nameLen <= len) {
                        return String(buf, q, nameLen, Charsets.US_ASCII)
                    }
                    return null
                }
                p += extLen
            }
        } catch (_: Exception) {
        }
        return null
    }
}
