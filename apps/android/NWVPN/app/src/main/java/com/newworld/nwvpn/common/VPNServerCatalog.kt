package com.newworld.nwvpn.common

import android.content.Context

data class VPNServerEntry(
    val displayName: String,
    val host: String,
) {
    val id: String get() = host
    val serverAddress: String get() = "$host:$defaultListenPort"

    companion object {
        private const val defaultListenPort = 8443
    }
}

object VPNServerCatalog {
    private val fallbackEntries = listOf(
        VPNServerEntry(displayName = "韩国", host = "new-world-kr-01.2fish.com.cn"),
    )

    fun normalizeConfigToken(raw: String): String {
        var s = raw.trim()
        if (s.startsWith("\uFEFF")) s = s.substring(1)
        return s.replace("\r", "")
    }

    fun normalizeHostLookup(raw: String): String {
        val t = normalizeConfigToken(raw)
        val idx = t.indexOf(':')
        if (idx < 0) return t
        val hostPart = t.substring(0, idx)
        val portPart = t.substring(idx + 1)
        if (!hostPart.contains(':') && !hostPart.contains('[') && portPart.toIntOrNull() != null) {
            return hostPart
        }
        return t
    }

    fun loadEntries(context: Context): List<VPNServerEntry> {
        val text = try {
            // readBytes() 内部对 InputStream 使用 use{}，保证 Asset 流关闭（减轻「resource failed to call close」类告警）
            context.assets.open("servers").readBytes().decodeToString()
        } catch (_: Exception) {
            return fallbackEntries
        }
        val out = mutableListOf<VPNServerEntry>()
        val textNoBom = if (text.startsWith("\uFEFF")) text.substring(1) else text
        for (rawLine in textNoBom.split('\n')) {
            val line = normalizeConfigToken(rawLine)
            if (line.isEmpty() || line.startsWith("#")) continue
            val parts = line.split(Regex("[\\t ]+")).filter { it.isNotEmpty() }
            if (parts.size < 2) continue
            val displayName = normalizeConfigToken(parts[0])
            val host = normalizeHostLookup(parts[1])
            if (host.isEmpty()) continue
            out.add(VPNServerEntry(displayName = displayName, host = host))
        }
        return if (out.isEmpty()) fallbackEntries else out
    }

    fun resolveServerAddress(context: Context, selectedHostRaw: String): String {
        return resolveServerAddressFromEntries(loadEntries(context), selectedHostRaw)
    }

    /** 已持有内存中的节点列表时使用，避免重复读 assets。 */
    fun resolveServerAddressFromEntries(entries: List<VPNServerEntry>, selectedHostRaw: String): String {
        val key = normalizeHostLookup(selectedHostRaw)
        entries.firstOrNull { normalizeHostLookup(it.host) == key }?.let { return it.serverAddress }
        return entries.firstOrNull()?.serverAddress ?: ""
    }

    /** 与 iOS `splitHostPort` 一致：无端口时默认 8443。 */
    fun splitHostPort(addr: String): Pair<String, Int>? {
        val t = addr.trim()
        if (t.isEmpty()) return null
        val r = t.indexOf(':')
        if (r >= 0) {
            val h = t.substring(0, r)
            val p = t.substring(r + 1)
            if (h.isNotEmpty() && p.isNotEmpty()) {
                val port = p.toIntOrNull() ?: return null
                return h to port
            }
        }
        return t to 8443
    }
}
