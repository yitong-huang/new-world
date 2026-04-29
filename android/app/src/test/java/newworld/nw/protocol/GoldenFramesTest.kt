package newworld.nw.protocol

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import java.net.InetAddress
import java.nio.ByteBuffer

class GoldenFramesTest {
    @Test
    fun goldenFramesMatchSpec() {
        val text = javaClass.getResourceAsStream("/golden_frames.json")!!.bufferedReader().use { it.readText() }
        val root = JSONObject(text)
        val arr = root.getJSONArray("frames")
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            val name = o.getString("name")
            val hex = o.getString("hex")
            val exp = o.getJSONObject("expect")
            val bytes = hexStringToByteArray(hex)
            val prefix = bytes.copyOf(NwProtocol.HEADER_SIZE)
            val (type, len) = NwProtocol.decodeHeader(prefix)
            assertEquals(exp.getInt("msg_type"), type.code)
            val payload = bytes.copyOfRange(NwProtocol.HEADER_SIZE, bytes.size)
            assertEquals(len, payload.size)
            when (type) {
                NwProtocol.MsgType.ClientHello -> {
                    val mtu = ByteBuffer.wrap(payload, 0, 2).short.toInt() and 0xffff
                    val caps = ByteBuffer.wrap(payload, 2, 4).int.toLong() and 0xffffffffL
                    assertEquals(exp.getJSONObject("client_hello").getInt("mtu"), mtu)
                    assertEquals(exp.getJSONObject("client_hello").getInt("caps").toLong(), caps)
                }
                NwProtocol.MsgType.ServerHello -> {
                    val mtu = ByteBuffer.wrap(payload, 0, 2).short.toInt() and 0xffff
                    assertEquals(exp.getJSONObject("server_hello").getInt("mtu"), mtu)
                }
                NwProtocol.MsgType.AssignTunnel -> {
                    val a = NwProtocol.decodeAssignTunnel(payload)
                    val want = exp.getJSONObject("assign_tunnel")
                    assertEquals(want.getString("ipv4"), InetAddress.getByAddress(a.ipv4).hostAddress)
                    assertEquals(want.getJSONArray("dns").getString(0), InetAddress.getByAddress(a.dns[0]).hostAddress)
                    assertEquals(want.getInt("flags"), a.flags)
                }
                NwProtocol.MsgType.Keepalive -> {}
                NwProtocol.MsgType.Error -> {
                    val (code, msg) = NwProtocol.decodeError(payload)
                    assertEquals(exp.getJSONObject("error").getInt("code"), code)
                    assertEquals(exp.getJSONObject("error").getString("msg"), msg)
                }
                NwProtocol.MsgType.Disconnect -> {
                    val (reason, msg) = NwProtocol.decodeDisconnect(payload)
                    assertEquals(exp.getJSONObject("disconnect").getInt("reason"), reason)
                    assertEquals(exp.getJSONObject("disconnect").getString("msg"), msg)
                }
                else -> throw AssertionError("unexpected $name")
            }
        }
    }

    private fun hexStringToByteArray(s: String): ByteArray {
        val clean = s.replace(" ", "")
        val out = ByteArray(clean.length / 2)
        var i = 0
        while (i < clean.length) {
            out[i / 2] = ((clean[i].digitToInt(16) shl 4) + clean[i + 1].digitToInt(16)).toByte()
            i += 2
        }
        return out
    }
}
