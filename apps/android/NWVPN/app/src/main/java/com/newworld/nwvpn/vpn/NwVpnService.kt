package com.newworld.nwvpn.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import com.newworld.nwvpn.MainActivity
import com.newworld.nwvpn.R
import com.newworld.nwvpn.state.TunnelState
import newworld.nw.protocol.NwProtocol
import org.json.JSONObject
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.lang.reflect.InvocationTargetException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import java.util.concurrent.locks.LockSupport
import kotlin.concurrent.thread

/**
 * TLS + NW 协议 TUN 中继；与仓库根目录 `android/` 示例逻辑一致。
 * 生产环境请替换 trust-all 为系统信任或证书固定。
 */
class NwVpnService : VpnService() {

    @Volatile
    private var tunPfd: ParcelFileDescriptor? = null

    @Volatile
    private var sslSocket: SSLSocket? = null

    @Volatile
    private var uplinkThread: Thread? = null

    @Volatile
    private var downlinkThread: Thread? = null

    private val tunnelLock = Any()
    private var tunnelRunning = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            TunnelState.setDisconnecting()
            shutdownTunnel()
            synchronized(tunnelLock) {
                if (!tunnelRunning) {
                    stopForegroundGracefully()
                    stopSelf(startId)
                    TunnelState.setDisconnected()
                }
            }
            return START_NOT_STICKY
        }

        val inIntent = intent ?: run {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val host = inIntent.getStringExtra(EXTRA_HOST)?.trim().orEmpty()
        if (host.isEmpty()) {
            stopSelf(startId)
            return START_NOT_STICKY
        }

        synchronized(tunnelLock) {
            if (tunnelRunning) {
                Log.w(TAG, "tunnel already running")
                return START_NOT_STICKY
            }
            tunnelRunning = true
        }

        ensureChannel()
        val initialNotif = buildNotification(getString(R.string.vpn_notification_title), "连接中…")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                initialNotif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIF_ID, initialNotif)
        }

        val port = inIntent.getIntExtra(EXTRA_PORT, 8443)
        val insecure = inIntent.getBooleanExtra(EXTRA_INSECURE, true)
        val user = inIntent.getStringExtra(EXTRA_USERNAME)?.trim().orEmpty()
        val pass = inIntent.getStringExtra(EXTRA_PASSWORD)?.trim().orEmpty()

        TunnelState.setConnecting()

        val workerStartId = startId
        thread(name = "nw-vpn") {
            try {
                val (u, p) = resolveAuth(user, pass)
                runTunnel(host, port, insecure, u, p)
                TunnelState.setDisconnected()
            } catch (e: Exception) {
                Log.e(TAG, "tunnel failed", e)
                TunnelState.setError(e.message ?: "连接失败")
            } finally {
                shutdownTunnel()
                stopForegroundGracefully()
                synchronized(tunnelLock) { tunnelRunning = false }
                stopSelf(workerStartId)
            }
        }
        return START_NOT_STICKY
    }

    private fun stopForegroundGracefully() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_DETACH)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(false)
        }
    }

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
        Log.i(TAG, "tcp connecting $host:$port")
        tcp.connect(InetSocketAddress(host, port), 15_000)
        val ssl = createSslSocket(tcp, host, port, insecure)
        sslSocket = ssl
        Log.i(TAG, "tls handshake start (insecure=$insecure)")
        ssl.startHandshake()
        Log.i(TAG, "tls handshake ok")

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
        // API 29+ 建议阻塞式 TUN（部分 AGP 的 android.jar 未声明 setBlockingSession，用反射调用）。
        applyBlockingTunIfAvailable(cfg)
        // 默认路由生效后，本进程到服务器的 TLS 若走 TUN 会形成回环；须把本应用排除在 VPN 之外（仍依赖 connect 前的 protect）。
        try {
            cfg.addDisallowedApplication(packageName)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "addDisallowedApplication", e)
        }
        Log.i(TAG, "vpn establish() …")
        val pfd: ParcelFileDescriptor = cfg.establish() ?: error("VpnService.establish() null")
        tunPfd = pfd
        Log.i(TAG, "vpn establish ok")

        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIF_ID, buildNotification(getString(R.string.vpn_notification_title), "已连接"))

        TunnelState.setConnected()

        val tunIn = FileInputStream(pfd.fileDescriptor)
        val tunOut = FileOutputStream(pfd.fileDescriptor)

        uplinkThread = thread {
            val buf = ByteArray(65535)
            while (true) {
                val n =
                    try {
                        tunIn.read(buf)
                    } catch (e: IOException) {
                        // 用户断开时 shutdownTunnel() 会关 PFD，read 可能 EBADF，须吞掉以免未捕获异常杀进程
                        Log.d(TAG, "tun uplink read end: ${e.message}")
                        break
                    }
                if (n > 0) {
                    try {
                        val pkt = buf.copyOf(n)
                        synchronized(out) {
                            out.write(NwProtocol.encodeFrame(NwProtocol.MsgType.Data, pkt))
                        }
                    } catch (e: IOException) {
                        Log.d(TAG, "tun uplink tls write end: ${e.message}")
                        break
                    }
                    continue
                }
                // 非阻塞 TUN 在无包时常返回 0；阻塞模式由 setBlockingSession 消除。反射失败时短 park 避免误当 EOF。
                if (n == 0) {
                    LockSupport.parkNanos(50_000L)
                    continue
                }
                break
            }
        }
        downlinkThread = thread {
            while (true) {
                val f = try {
                    NwProtocol.readFrame(inn)
                } catch (_: Exception) {
                    break
                }
                try {
                    when (f.type) {
                        NwProtocol.MsgType.Data -> tunOut.write(f.payload)
                        NwProtocol.MsgType.Keepalive -> synchronized(out) {
                            out.write(NwProtocol.encodeFrame(NwProtocol.MsgType.Keepalive, ByteArray(0)))
                        }
                        else -> {}
                    }
                } catch (e: IOException) {
                    Log.d(TAG, "tun downlink write end: ${e.message}")
                    break
                }
            }
        }
        uplinkThread?.join()
        downlinkThread?.interrupt()
        try {
            pfd.close()
        } catch (_: Exception) {
        }
        tunPfd = null
        try {
            ssl.close()
        } catch (_: Exception) {
        }
        sslSocket = null
    }

    private fun shutdownTunnel() {
        try {
            tunPfd?.close()
        } catch (_: Exception) {
        }
        tunPfd = null
        try {
            sslSocket?.close()
        } catch (_: Exception) {
        }
        sslSocket = null
        uplinkThread?.interrupt()
        downlinkThread?.interrupt()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java)
        val ch = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.vpn_notification_channel),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = getString(R.string.vpn_notification_channel_desc)
            setShowBadge(false)
        }
        nm.createNotificationChannel(ch)
    }

    private fun buildNotification(title: String, text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_nwvpn)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    /** API 29+ 将 TUN 置于阻塞模式；部分 ROM / android.jar 上需沿实例类或 declaredMethods 查找。 */
    private fun applyBlockingTunIfAvailable(cfg: VpnService.Builder): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val boolType = java.lang.Boolean.TYPE
        val attempts =
            listOf<() -> Unit>(
                {
                    val m = cfg.javaClass.getMethod("setBlockingSession", boolType)
                    m.invoke(cfg, true)
                },
                {
                    var found: java.lang.reflect.Method? = null
                    var cl: Class<*>? = cfg.javaClass
                    while (cl != null && found == null) {
                        for (dm in cl.declaredMethods) {
                            if (dm.name != "setBlockingSession" || dm.parameterCount != 1) continue
                            if (dm.parameterTypes[0] != boolType) continue
                            found = dm
                            break
                        }
                        cl = cl.superclass
                    }
                    val m = found ?: error("setBlockingSession not in hierarchy")
                    m.isAccessible = true
                    m.invoke(cfg, true)
                },
                {
                    val clazz = Class.forName("android.net.VpnService\$Builder")
                    val m = clazz.getDeclaredMethod("setBlockingSession", boolType)
                    m.isAccessible = true
                    m.invoke(cfg, true)
                },
            )
        for (block in attempts) {
            try {
                block()
                return true
            } catch (e: InvocationTargetException) {
                Log.w(TAG, "setBlockingSession", e.cause ?: e)
            } catch (e: Exception) {
                Log.w(TAG, "setBlockingSession", e)
            }
        }
        return false
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
        val ssl = factory.createSocket(tcp, host, port, true) as SSLSocket
        // trust-all 仍会做 HTTPS 式主机名校验；自签 SAN 与域名不一致时握手会立刻失败。
        if (insecure && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            ssl.sslParameters = ssl.sslParameters.apply {
                endpointIdentificationAlgorithm = null
            }
        }
        return ssl
    }

    companion object {
        private const val TAG = "NwVpnService"
        const val ACTION_STOP = "com.newworld.nwvpn.STOP_TUNNEL"
        const val EXTRA_HOST = "host"
        const val EXTRA_PORT = "port"
        const val EXTRA_INSECURE = "insecure"
        const val EXTRA_USERNAME = "username"
        const val EXTRA_PASSWORD = "password"
        const val EXTRA_CHINA_DIRECT = "china_direct"

        private const val CHANNEL_ID = "nw_vpn"
        private const val NOTIF_ID = 7701

        fun stopTunnel(context: Context) {
            context.startService(
                Intent(context, NwVpnService::class.java).setAction(ACTION_STOP),
            )
        }
    }
}
