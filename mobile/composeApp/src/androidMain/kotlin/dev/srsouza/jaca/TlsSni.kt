package dev.srsouza.jaca

/// Minimal TLS ClientHello SNI parser — extracts the server hostname so the tunnel bridge
/// knows where to CONNECT (or fall back to). Pure, testable, no allocations beyond the result.
object TlsSni {
    /// Parse the SNI host from a buffer that begins with a TLS record, or null if absent /
    /// incomplete / not a ClientHello.
    fun host(buf: ByteArray, len: Int): String? {
        var p = 0
        fun u8(i: Int) = buf[i].toInt() and 0xFF
        fun u16(i: Int) = (u8(i) shl 8) or u8(i + 1)

        if (len < 5) return null
        if (u8(0) != 0x16) return null          // not a handshake record
        p = 5                                    // skip TLS record header
        if (p + 4 > len) return null
        if (u8(p) != 0x01) return null           // not ClientHello
        val hsLen = (u8(p + 1) shl 16) or (u8(p + 2) shl 8) or u8(p + 3)
        p += 4
        val hsEnd = minOf(p + hsLen, len)
        if (p + 2 + 32 > hsEnd) return null
        p += 2 + 32                              // client_version + random
        if (p + 1 > hsEnd) return null
        p += 1 + u8(p)                           // session_id
        if (p + 2 > hsEnd) return null
        p += 2 + u16(p)                          // cipher_suites
        if (p + 1 > hsEnd) return null
        p += 1 + u8(p)                           // compression_methods
        if (p + 2 > hsEnd) return null
        var extEnd = p + 2 + u16(p)
        p += 2
        extEnd = minOf(extEnd, hsEnd)
        while (p + 4 <= extEnd) {
            val type = u16(p)
            val extLen = u16(p + 2)
            p += 4
            if (type == 0x0000) {                // server_name extension
                if (p + 5 > extEnd) return null
                // server_name_list(2) + name_type(1) + host_name length(2)
                val nameLen = u16(p + 3)
                val start = p + 5
                if (start + nameLen > len) return null
                return String(buf, start, nameLen, Charsets.US_ASCII)
            }
            p += extLen
        }
        return null
    }
}
