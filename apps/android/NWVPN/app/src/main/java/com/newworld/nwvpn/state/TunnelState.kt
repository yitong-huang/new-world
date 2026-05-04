package com.newworld.nwvpn.state

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class VpnConnectionPhase {
    Disconnected,
    Connecting,
    Connected,
    Disconnecting,
}

object TunnelState {
    private val _phase = MutableStateFlow(VpnConnectionPhase.Disconnected)
    val phase: StateFlow<VpnConnectionPhase> = _phase.asStateFlow()

    private val _statusText = MutableStateFlow("未连接")
    val statusText: StateFlow<String> = _statusText.asStateFlow()

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    fun setConnecting() {
        _lastError.value = null
        _phase.value = VpnConnectionPhase.Connecting
        _statusText.value = "连接中…"
    }

    fun setConnected() {
        _lastError.value = null
        _phase.value = VpnConnectionPhase.Connected
        _statusText.value = "已连接"
    }

    fun setDisconnecting() {
        _phase.value = VpnConnectionPhase.Disconnecting
        _statusText.value = "断开中…"
    }

    fun setDisconnected(message: String? = null) {
        _phase.value = VpnConnectionPhase.Disconnected
        _statusText.value = "未连接"
        if (message != null) {
            _lastError.value = message
        } else if (_lastError.value.isNullOrEmpty()) {
            _lastError.value = "隧道已断开（可先关闭「国内直连」重试）"
        }
    }

    fun setError(message: String) {
        if (_phase.value == VpnConnectionPhase.Connecting) {
            _phase.value = VpnConnectionPhase.Disconnected
            _statusText.value = "未连接"
        }
        _lastError.value = message
    }
}
