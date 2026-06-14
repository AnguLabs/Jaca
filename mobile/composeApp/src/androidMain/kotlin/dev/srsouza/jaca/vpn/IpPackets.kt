package dev.srsouza.jaca.vpn

import java.net.InetAddress

/// IPv4 / TCP / UDP header read+write over a raw packet buffer, with checksum
/// recomputation. Ported from NetBare (github.com/MegatronKing/NetBare, MIT) — the
/// proven technique for VpnService interception. Offsets and checksum math mirror the
/// original; this is the foundation for the header rewriting that redirects connections
/// to our local proxy while the kernel does TCP/UDP.
abstract class Header(@JvmField val packet: ByteArray, @JvmField var offset: Int) {
    fun readByte(o: Int): Byte = packet[o]
    fun writeByte(v: Byte, o: Int) { packet[o] = v }
    fun readShort(o: Int): Short =
        (((packet[o].toInt() and 0xFF) shl 8) or (packet[o + 1].toInt() and 0xFF)).toShort()
    fun writeShort(v: Short, o: Int) {
        packet[o] = (v.toInt() shr 8).toByte()
        packet[o + 1] = v.toByte()
    }
    fun readInt(o: Int): Int =
        ((packet[o].toInt() and 0xFF) shl 24) or ((packet[o + 1].toInt() and 0xFF) shl 16) or
        ((packet[o + 2].toInt() and 0xFF) shl 8) or (packet[o + 3].toInt() and 0xFF)
    fun writeInt(v: Int, o: Int) {
        packet[o] = (v shr 24).toByte()
        packet[o + 1] = (v shr 16).toByte()
        packet[o + 2] = (v shr 8).toByte()
        packet[o + 3] = v.toByte()
    }
    fun getSum(start: Int, length: Int): Long {
        var sum = 0L
        var o = start
        var len = length
        while (len > 1) {
            sum += (readShort(o).toInt() and 0xFFFF).toLong()
            o += 2; len -= 2
        }
        if (len > 0) sum += ((packet[o].toInt() and 0xFF) shl 8).toLong()
        return sum
    }
}

enum class Protocol(@JvmField val number: Byte) {
    ICMP(1), TCP(6), UDP(17);
    companion object {
        fun parse(number: Int): Protocol? = entries.firstOrNull { it.number.toInt() == number }
    }
}

class IpHeader(packet: ByteArray, offset: Int) : Header(packet, offset) {
    fun version(): Int = (packet[offset].toInt() ushr 4) and 0xF
    fun getProtocol(): Byte = packet[offset + OFFSET_PROTOCOL]
    fun getHeaderLength(): Int = (packet[offset].toInt() and 0x0F) * 4
    fun getSourceIp(): Int = readInt(offset + OFFSET_SRC_IP)
    fun setSourceIp(ip: Int) = writeInt(ip, offset + OFFSET_SRC_IP)
    fun getDestinationIp(): Int = readInt(offset + OFFSET_DEST_IP)
    fun setDestinationIp(ip: Int) = writeInt(ip, offset + OFFSET_DEST_IP)
    fun getTotalLength(): Int = readShort(offset + OFFSET_TLEN).toInt() and 0xFFFF
    fun setTotalLength(len: Short) = writeShort(len, offset + OFFSET_TLEN)
    fun getDataLength(): Int = getTotalLength() - getHeaderLength()
    private fun setCrc(crc: Short) = writeShort(crc, offset + OFFSET_CRC)
    fun getIpSum(): Long = getSum(offset + OFFSET_SRC_IP, 8)
    fun updateChecksum() { setCrc(0); setCrc(computeChecksum()) }
    private fun computeChecksum(): Short {
        var sum = getSum(offset, getHeaderLength())
        while ((sum shr 16) > 0) sum = (sum and 0xFFFF) + (sum shr 16)
        return sum.inv().toShort()
    }
    companion object {
        const val OFFSET_PROTOCOL = 9
        const val OFFSET_SRC_IP = 12
        const val OFFSET_DEST_IP = 16
        const val OFFSET_TLEN = 2
        const val OFFSET_CRC = 10
    }
}

class TcpHeader(private val ip: IpHeader, packet: ByteArray, offset: Int) : Header(packet, offset) {
    fun getSourcePort(): Short = readShort(offset + OFFSET_SRC_PORT)
    fun setSourcePort(p: Short) = writeShort(p, offset + OFFSET_SRC_PORT)
    fun getDestinationPort(): Short = readShort(offset + OFFSET_DEST_PORT)
    fun setDestinationPort(p: Short) = writeShort(p, offset + OFFSET_DEST_PORT)
    fun getHeaderLength(): Int = ((packet[offset + OFFSET_LENRES].toInt() and 0xFF) shr 4) * 4
    fun getFlag(): Byte = packet[offset + OFFSET_FLAG]
    private fun setCrc(crc: Short) = writeShort(crc, offset + OFFSET_CRC)
    fun updateChecksum() { setCrc(0); setCrc(computeChecksum()) }
    private fun computeChecksum(): Short {
        val dataLength = ip.getDataLength()
        var sum = ip.getIpSum()
        sum += (ip.getProtocol().toInt() and 0xFF).toLong()
        sum += dataLength.toLong()
        sum += getSum(offset, dataLength)
        while ((sum shr 16) > 0) sum = (sum and 0xFFFF) + (sum shr 16)
        return sum.inv().toShort()
    }
    companion object {
        const val OFFSET_SRC_PORT = 0
        const val OFFSET_DEST_PORT = 2
        const val OFFSET_LENRES = 12
        const val OFFSET_CRC = 16
        const val OFFSET_FLAG = 13
        const val SYN = 2
    }
}

class UdpHeader(val ip: IpHeader, packet: ByteArray, offset: Int) : Header(packet, offset) {
    fun getSourcePort(): Short = readShort(offset + OFFSET_SRC_PORT)
    fun setSourcePort(p: Short) = writeShort(p, offset + OFFSET_SRC_PORT)
    fun getDestinationPort(): Short = readShort(offset + OFFSET_DEST_PORT)
    fun setDestinationPort(p: Short) = writeShort(p, offset + OFFSET_DEST_PORT)
    fun getHeaderLength(): Int = 8
    fun setTotalLength(len: Short) = writeShort(len, offset + OFFSET_TLEN)
    private fun setCrc(crc: Short) = writeShort(crc, offset + OFFSET_CRC)
    fun updateChecksum() { setCrc(0); setCrc(computeChecksum()) }
    private fun computeChecksum(): Short {
        val dataLength = ip.getDataLength()
        var sum = ip.getIpSum()
        sum += (ip.getProtocol().toInt() and 0xFF).toLong()
        sum += dataLength.toLong()
        sum += getSum(offset, dataLength)
        while ((sum shr 16) > 0) sum = (sum and 0xFFFF) + (sum shr 16)
        return sum.inv().toShort()
    }
    /// Payload bytes (after IP+UDP headers).
    fun data(): ByteArray {
        val size = ip.getDataLength() - getHeaderLength()
        val dataOffset = ip.getHeaderLength() + getHeaderLength()
        return packet.copyOfRange(dataOffset, dataOffset + size)
    }
    /// Deep copy of the whole packet, wrapped in new headers.
    fun copy(): UdpHeader {
        val arr = packet.copyOf()
        return UdpHeader(IpHeader(arr, 0), arr, offset)
    }
    companion object {
        const val OFFSET_SRC_PORT = 0
        const val OFFSET_DEST_PORT = 2
        const val OFFSET_TLEN = 4
        const val OFFSET_CRC = 6
    }
}

/// "10.0.0.2" -> big-endian int matching IpHeader.readInt.
fun ipToInt(ip: String): Int {
    val p = ip.split(".")
    return ((p[0].toInt() and 0xFF) shl 24) or ((p[1].toInt() and 0xFF) shl 16) or
        ((p[2].toInt() and 0xFF) shl 8) or (p[3].toInt() and 0xFF)
}

fun intToIp(ip: Int): String =
    "${(ip ushr 24) and 0xFF}.${(ip ushr 16) and 0xFF}.${(ip ushr 8) and 0xFF}.${ip and 0xFF}"

fun intToInetAddress(ip: Int): InetAddress = InetAddress.getByAddress(
    byteArrayOf((ip ushr 24).toByte(), (ip ushr 16).toByte(), (ip ushr 8).toByte(), ip.toByte()),
)

fun Short.toUnsignedPort(): Int = this.toInt() and 0xFFFF
