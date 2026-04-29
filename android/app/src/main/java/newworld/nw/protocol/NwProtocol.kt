package newworld.nw.protocol

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets

object NwProtocol {
    const val HEADER_SIZE = 12

    /** ClientHello.caps bit1: next frame is AuthCredentials. */
    const val CAP_AUTH_NEXT = 1 shl 1

    enum class MsgType(val code: Int) {
        ClientHello(1),
        ServerHello(2),
        AssignTunnel(3),
        Data(4),
        Keepalive(5),
        Error(6),
        Disconnect(7),
        AuthCredentials(8),
    }

    fun encodeFrame(type: MsgType, payload: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(HEADER_SIZE + payload.size)
        out.write(byteArrayOf('N'.code.toByte(), 'W'.code.toByte(), '0'.code.toByte(), '1'.code.toByte()))
        out.write(byteArrayOf(0, 1)) // version BE
        out.write(type.code)
        out.write(0) // reserved
        val bb = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN)
        bb.putInt(payload.size)
        out.write(bb.array())
        out.write(payload)
        return out.toByteArray()
    }

    data class Frame(val type: MsgType, val payload: ByteArray)

    fun decodeHeader(prefix: ByteArray): Pair<MsgType, Int> {
        require(prefix.size >= HEADER_SIZE)
        if (prefix[0] != 'N'.code.toByte() || prefix[1] != 'W'.code.toByte() ||
            prefix[2] != '0'.code.toByte() || prefix[3] != '1'.code.toByte()
        ) {
            throw IllegalArgumentException("bad magic")
        }
        val ver = ((prefix[4].toInt() and 0xff) shl 8) or (prefix[5].toInt() and 0xff)
        if (ver != 1) throw IllegalArgumentException("bad version")
        val t = prefix[6].toInt() and 0xff
        val type = MsgType.values().firstOrNull { it.code == t } ?: throw IllegalArgumentException("bad type")
        val len = ByteBuffer.wrap(prefix, 8, 4).order(ByteOrder.BIG_ENDIAN).int
        if (len < 0 || len > 1_048_576 - HEADER_SIZE) throw IllegalArgumentException("bad length")
        return type to len
    }

    fun encodeClientHello(mtu: Int, caps: Int): ByteArray {
        val bb = ByteBuffer.allocate(6).order(ByteOrder.BIG_ENDIAN)
        bb.putShort(mtu.toShort())
        bb.putInt(caps)
        return bb.array()
    }

    private const val MAX_AUTH_UTF8 = 512

    fun encodeAuthCredentials(user: String, pass: String): ByteArray {
        val u = user.toByteArray(StandardCharsets.UTF_8)
        val p = pass.toByteArray(StandardCharsets.UTF_8)
        require(u.size <= MAX_AUTH_UTF8 && p.size <= MAX_AUTH_UTF8)
        val bb = ByteBuffer.allocate(2 + u.size + 2 + p.size).order(ByteOrder.BIG_ENDIAN)
        bb.putShort(u.size.toShort())
        bb.put(u)
        bb.putShort(p.size.toShort())
        bb.put(p)
        return bb.array()
    }

    fun readFrame(input: java.io.InputStream): Frame {
        val hdr = ByteArray(HEADER_SIZE)
        readFully(input, hdr)
        val (t, len) = decodeHeader(hdr)
        val payload = ByteArray(len)
        if (len > 0) readFully(input, payload)
        return Frame(t, payload)
    }

    private fun readFully(input: java.io.InputStream, b: ByteArray) {
        var off = 0
        while (off < b.size) {
            val n = input.read(b, off, b.size - off)
            if (n < 0) throw java.io.EOFException()
            off += n
        }
    }

    data class AssignTunnel(val ipv4: ByteArray, val dns: List<ByteArray>, val flags: Int)

    fun decodeAssignTunnel(payload: ByteArray): AssignTunnel {
        require(payload.size >= 4 + 1 + 1)
        val ipv4 = payload.copyOfRange(0, 4)
        val n = payload[4].toInt() and 0xff
        require(n in 0..4)
        require(payload.size >= 5 + 4 * n + 1)
        val dns = mutableListOf<ByteArray>()
        for (i in 0 until n) {
            dns.add(payload.copyOfRange(5 + 4 * i, 5 + 4 * (i + 1)))
        }
        val flags = payload[5 + 4 * n].toInt() and 0xff
        return AssignTunnel(ipv4, dns, flags)
    }

    fun decodeError(payload: ByteArray): Pair<Int, String> {
        require(payload.size >= 4)
        val code = ((payload[0].toInt() and 0xff) shl 8) or (payload[1].toInt() and 0xff)
        val ml = ((payload[2].toInt() and 0xff) shl 8) or (payload[3].toInt() and 0xff)
        require(payload.size >= 4 + ml)
        val msg = String(payload, 4, ml, StandardCharsets.UTF_8)
        return code to msg
    }

    fun decodeDisconnect(payload: ByteArray): Pair<Int, String> {
        require(payload.size >= 3)
        val reason = payload[0].toInt() and 0xff
        val ml = ((payload[1].toInt() and 0xff) shl 8) or (payload[2].toInt() and 0xff)
        require(payload.size >= 3 + ml)
        val msg = String(payload, 3, ml, StandardCharsets.UTF_8)
        return reason to msg
    }
}
