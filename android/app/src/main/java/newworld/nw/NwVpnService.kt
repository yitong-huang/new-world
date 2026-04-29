package newworld.nw

import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log
import newworld.nw.protocol.NwProtocol
import org.json.JSONObject
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import kotlin.concurrent.thread

/**
 * Minimal Packet Tunnel: TLS + NW handshake, then TUN FD <-> TLS relay (blocking threads).
 * For production, replace trust-all with pinned certs / system trust + hostname verify.
 */
class NwVpnService : VpnService() {

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val host = intent?.getStringExtra("host") ?: return START_NOT_STICKY
        val port = intent.getIntExtra("port", 8443)
        val insecure = intent.getBooleanExtra("insecure", true)
        val user = intent.getStringExtra("username")?.trim().orEmpty()
        val pass = intent.getStringExtra("password")?.trim().orEmpty()
        thread(name = "nw-vpn") {
            try {
                val (u, p) = resolveAuth(user, pass)
                runTunnel(host, port, insecure, u, p)
            } catch (e: Exception) {
                Log.e(TAG, "tunnel failed", e)
            } finally {
                stopSelf(startId)
            }
        }
        return START_STICKY
    }

    /** Prefer intent extras; else read `files/nw_auth.json` (same shape as configs/auth.client.example.json). */
    private fun resolveAuth(intentUser: String, intentPass: String): Pair<String, String> {
        if (intentUser.isNotEmpty()) return intentUser to intentPass
        return try {
            val f = getFileStreamPath("nw_auth.json")
            if (!f.exists()) return "" to ""
            val o = JSONObject(f.readText())
            o.getString("username") to o.getString("password")
        } catch (e: Exception) {
            Log.w(TAG, "nw_auth.json unreadable", e)
            "" to ""
        }
    }

    private fun runTunnel(host: String, port: Int, insecure: Boolean, authUser: String, authPass: String) {
        val tcp = Socket()
        protect(tcp)
        tcp.connect(InetSocketAddress(host, port), 15_000)
        val ssl = createSslSocket(tcp, host, port, insecure)
        ssl.startHandshake()

        val out = ssl.getOutputStream()
        val inn = ssl.getInputStream()

        val caps = if (authUser.isNotEmpty()) NwProtocol.CAP_AUTH_NEXT else 0
        val ch = NwProtocol.encodeClientHello(1400, caps)
        out.write(NwProtocol.encodeFrame(NwProtocol.MsgType.ClientHello, ch))
        if (authUser.isNotEmpty()) {
            val ap = NwProtocol.encodeAuthCredentials(authUser, authPass)
            out.write(NwProtocol.encodeFrame(NwProtocol.MsgType.AuthCredentials, ap))
        }

        var fr = NwProtocol.readFrame(inn)
        if (fr.type == NwProtocol.MsgType.Error) {
            val (c, m) = NwProtocol.decodeError(fr.payload)
            error("server error $c: $m")
        }
        require(fr.type == NwProtocol.MsgType.ServerHello) { "expected ServerHello" }
        fr = NwProtocol.readFrame(inn)
        require(fr.type == NwProtocol.MsgType.AssignTunnel) { "expected AssignTunnel" }
        val assign = NwProtocol.decodeAssignTunnel(fr.payload)

        val cfg = Builder()
            .setSession("NWVPN")
            .setConfigureIntent(
                PendingIntent.getActivity(
                    this,
                    0,
                    Intent(this, MainActivity::class.java),
                    PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            .addAddress(InetAddress.getByAddress(assign.ipv4), 32)
        for (d in assign.dns) {
            cfg.addDnsServer(InetAddress.getByAddress(d))
        }
        cfg.addRoute("0.0.0.0", 1)
        cfg.addRoute("128.0.0.0", 1)
        cfg.setMtu(1400)
        val pfd: ParcelFileDescriptor = cfg.establish() ?: error("VpnService.establish() null")

        val tunIn = FileInputStream(pfd.fileDescriptor)
        val tunOut = FileOutputStream(pfd.fileDescriptor)

        val up = thread {
            val buf = ByteArray(65535)
            while (true) {
                val n = tunIn.read(buf)
                if (n <= 0) break
                val pkt = buf.copyOf(n)
                synchronized(out) {
                    out.write(NwProtocol.encodeFrame(NwProtocol.MsgType.Data, pkt))
                }
            }
        }
        val down = thread {
            while (true) {
                val f = try {
                    NwProtocol.readFrame(inn)
                } catch (_: Exception) {
                    break
                }
                when (f.type) {
                    NwProtocol.MsgType.Data -> tunOut.write(f.payload)
                    NwProtocol.MsgType.Keepalive -> synchronized(out) {
                        out.write(NwProtocol.encodeFrame(NwProtocol.MsgType.Keepalive, ByteArray(0)))
                    }
                    else -> {}
                }
            }
        }
        up.join()
        down.interrupt()
        pfd.close()
        ssl.close()
    }

    private fun createSslSocket(tcp: Socket, host: String, port: Int, insecure: Boolean): SSLSocket {
        val factory: SSLSocketFactory = if (insecure) {
            val ctx = SSLContext.getInstance("TLS")
            val trustAll = object : X509TrustManager {
                override fun checkClientTrusted(chain: Array<java.security.cert.X509Certificate>, authType: String) {}
                override fun checkServerTrusted(chain: Array<java.security.cert.X509Certificate>, authType: String) {}
                override fun getAcceptedIssuers(): Array<java.security.cert.X509Certificate> = arrayOf()
            }
            ctx.init(null, arrayOf<TrustManager>(trustAll), java.security.SecureRandom())
            ctx.socketFactory as SSLSocketFactory
        } else {
            SSLContext.getDefault().socketFactory as SSLSocketFactory
        }
        return factory.createSocket(tcp, host, port, true) as SSLSocket
    }

    companion object {
        private const val TAG = "NwVpnService"
    }
}
