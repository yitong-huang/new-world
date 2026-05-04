package com.newworld.nwvpn

import android.app.Application
import android.content.Intent
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.newworld.nwvpn.common.VPNServerCatalog
import com.newworld.nwvpn.common.VPNServerEntry
import com.newworld.nwvpn.state.TunnelState
import com.newworld.nwvpn.state.VpnConnectionPhase
import com.newworld.nwvpn.vpn.NwVpnService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class HomeViewModel(application: Application) : AndroidViewModel(application) {

    private val prefs = application.getSharedPreferences("nwvpn", Application.MODE_PRIVATE)

    private val _nodes = MutableStateFlow<List<VPNServerEntry>>(emptyList())
    val nodes: StateFlow<List<VPNServerEntry>> = _nodes.asStateFlow()

    private val _selectedHost = MutableStateFlow(prefs.getString(NodePrefs.selectedHostKey, "").orEmpty())
    val selectedHost: StateFlow<String> = _selectedHost.asStateFlow()

    private val _username = MutableStateFlow("")
    val username: StateFlow<String> = _username.asStateFlow()

    private val _password = MutableStateFlow("")
    val password: StateFlow<String> = _password.asStateFlow()

    private val _chinaDirect = MutableStateFlow(false)
    val chinaDirect: StateFlow<Boolean> = _chinaDirect.asStateFlow()

    private var lastStatusTapMs = 0L

    init {
        viewModelScope.launch { refreshCatalogFromDisk() }
    }

    fun reloadCatalog() {
        viewModelScope.launch { refreshCatalogFromDisk() }
    }

    private suspend fun refreshCatalogFromDisk() {
        val app = getApplication<Application>()
        val list = withContext(Dispatchers.IO) {
            VPNServerCatalog.loadEntries(app)
        }
        _nodes.value = list
        normalizeSelection(list)
    }

    private fun normalizeSelection(list: List<VPNServerEntry>) {
        var cur = _selectedHost.value
        val key = VPNServerCatalog.normalizeHostLookup(cur)
        val match = list.firstOrNull { VPNServerCatalog.normalizeHostLookup(it.host) == key }
        if (match != null) {
            if (cur != match.host) cur = match.host
            _selectedHost.value = cur
            prefs.edit().putString(NodePrefs.selectedHostKey, cur).apply()
            return
        }
        val first = list.firstOrNull()
        if (first != null) {
            _selectedHost.value = first.host
            prefs.edit().putString(NodePrefs.selectedHostKey, first.host).apply()
        } else {
            _selectedHost.value = ""
        }
    }

    fun selectHost(host: String) {
        _selectedHost.value = host
        prefs.edit().putString(NodePrefs.selectedHostKey, host).apply()
    }

    fun setUsername(v: String) {
        _username.value = v
    }

    fun setPassword(v: String) {
        _password.value = v
    }

    fun setChinaDirect(v: Boolean) {
        _chinaDirect.value = v
    }

    fun onVpnPermissionResult(granted: Boolean) {
        if (granted) {
            performConnect()
        } else {
            TunnelState.setError("VPN 权限被拒绝")
        }
    }

    /** 若返回 false，表示已忽略（连点节流）。 */
    fun tryConsumeStatusTap(): Boolean {
        val now = System.currentTimeMillis()
        if (now - lastStatusTapMs < 450) return false
        lastStatusTapMs = now
        return true
    }

    fun performConnect() {
        viewModelScope.launch {
            refreshCatalogFromDisk()
            val ctx = getApplication<Application>()
            val addr = VPNServerCatalog.resolveServerAddressFromEntries(_nodes.value, _selectedHost.value)
            val split = VPNServerCatalog.splitHostPort(addr) ?: run {
                TunnelState.setError("服务器地址无效")
                return@launch
            }
            val intent = Intent(ctx, NwVpnService::class.java).apply {
                putExtra(NwVpnService.EXTRA_HOST, split.first)
                putExtra(NwVpnService.EXTRA_PORT, split.second)
                putExtra(NwVpnService.EXTRA_INSECURE, true)
                val u = _username.value.trim()
                val p = _password.value
                if (u.isNotEmpty()) {
                    putExtra(NwVpnService.EXTRA_USERNAME, u)
                    putExtra(NwVpnService.EXTRA_PASSWORD, p)
                }
                putExtra(NwVpnService.EXTRA_CHINA_DIRECT, _chinaDirect.value)
            }
            ContextCompat.startForegroundService(ctx, intent)
        }
    }

    fun statusRowTappable(): Boolean {
        if (TunnelState.statusText.value == "加载中…" || TunnelState.statusText.value == "偏好设置错误") return false
        return when (TunnelState.phase.value) {
            VpnConnectionPhase.Connected -> true
            // 节点在 IO 线程异步加载；未加载完时 _nodes 仍为空，若要求 isNotEmpty 会导致 clickable(enabled=false) 完全无反馈。
            // performConnect 内会先 refreshCatalogFromDisk()，与 iOS 同步加载的体验对齐。
            VpnConnectionPhase.Disconnected -> true
            else -> false
        }
    }

    companion object {
        object NodePrefs {
            const val selectedHostKey = "NewWorldVPN.node.selectedHost"
        }
    }
}
