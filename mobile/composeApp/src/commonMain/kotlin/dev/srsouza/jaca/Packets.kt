package dev.srsouza.jaca

/// One parsed transport flow (IPv4 TCP or UDP) from a tun packet.
data class Flow(
    val protocol: Int,    // 6 = TCP, 17 = UDP
    val srcIp: String,
    val srcPort: Int,
    val dstIp: String,
    val dstPort: Int,
) {
    /// Stable per-connection key for dedup.
    val key: String get() = "$protocol|$srcIp:$srcPort>$dstIp:$dstPort"
}

/// A captured connection attributed to an app — what the UI shows / filters by.
data class CapturedFlow(
    val app: String,
    val packageName: String,
    val host: String,
    val port: Int,
    val protocol: String,   // "TCP" / "UDP"
)

/// Minimal, pure-Kotlin IPv4 TCP/UDP header parser (testable, reusable for iOS later).
object PacketParser {
    fun parse(buf: ByteArray, len: Int): Flow? {
        if (len < 20) return null
        if (((buf[0].toInt() ushr 4) and 0xF) != 4) return null   // IPv4 only for now
        val ihl = (buf[0].toInt() and 0xF) * 4
        if (ihl < 20 || len < ihl + 4) return null
        val protocol = buf[9].toInt() and 0xFF
        if (protocol != 6 && protocol != 17) return null           // TCP or UDP
        return Flow(
            protocol = protocol,
            srcIp = ipv4(buf, 12),
            dstIp = ipv4(buf, 16),
            srcPort = u16(buf, ihl),
            dstPort = u16(buf, ihl + 2),
        )
    }

    private fun u16(b: ByteArray, o: Int) =
        ((b[o].toInt() and 0xFF) shl 8) or (b[o + 1].toInt() and 0xFF)

    private fun ipv4(b: ByteArray, o: Int) =
        "${b[o].toInt() and 0xFF}.${b[o + 1].toInt() and 0xFF}." +
        "${b[o + 2].toInt() and 0xFF}.${b[o + 3].toInt() and 0xFF}"
}
