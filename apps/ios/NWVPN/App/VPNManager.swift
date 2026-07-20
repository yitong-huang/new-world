import Foundation
import NetworkExtension
import OSLog
import UIKit

@MainActor
final class VPNManager: ObservableObject {
    /// 与扩展 `Logger(subsystem: "com.newworld.nwvpn.ios", …)` 同子系统，Console 可按 subsystem 一次看全。
    private let disconnectDiagLog = Logger(subsystem: "com.newworld.nwvpn.ios", category: "VPNManager")
    @Published private(set) var statusText = "加载中…"
    /// 与系统 VPN 连接状态一致，供界面着色（红/蓝）与点击切换。
    @Published private(set) var neConnectionStatus: NEVPNStatus = .invalid
    @Published var lastError: String?
    /// 正在 save/load 偏好并拉起隧道时设为 true，避免连点触发多路 NE 并发（Console 会看到扩展、保存配置各出现多份）。
    @Published private(set) var tunnelConfigurationBusy = false

    /// 同步门闸：`@Published` 可能在同一 runloop 内尚未刷新，连点仍会进入 connect；用锁保证整段流程互斥。
    private let connectFlowLock = NSLock()
    private var connectFlowActive = false

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    /// 长时间停留在系统 `.connecting`（例如对端无响应）时，主动 `stopVPNTunnel`，避免界面一直显示「连接中…」。
    private var connectingTimeoutWorkItem: DispatchWorkItem?
    /// 非用户主动断开时，延迟后自动重连。
    private var autoReconnectWorkItem: DispatchWorkItem?
    private var autoReconnectAttempt = 0
    private var userRequestedDisconnect = false

    private struct ConnectParams {
        let host: String
        let port: String
        let username: String
        let password: String
        let chinaDirect: Bool
    }

    private var lastConnectParams: ConnectParams?

    /// 与 `project.yml` 中扩展的 `PRODUCT_BUNDLE_IDENTIFIER` 一致。
    private let extensionBundleId = "com.newworld.NWVPNiOS.PacketTunnel"

    /// 秒；超过此时间仍为 `NEVPNStatus.connecting` 则视为失败并断开。
    private static let connectingTimeoutSeconds: TimeInterval = 10
    private static let autoReconnectBaseDelaySeconds: TimeInterval = 2
    private static let autoReconnectMaxDelaySeconds: TimeInterval = 60

    private enum AgentDebugLog {
        private static let sessionId = "2902a2"
        private static let dbgLogger = Logger(subsystem: "com.newworld.nwvpn.ios.debug", category: "AppNDJSON")

        private struct Entry: Codable {
            let sessionId: String
            let runId: String
            let hypothesisId: String
            let location: String
            let message: String
            let timestamp: Int64
            let data: [String: String]
        }

        static func log(runId: String = "pre-fix", hypothesisId: String, location: String, message: String, data: [String: String] = [:]) {
            let entry = Entry(
                sessionId: sessionId,
                runId: runId,
                hypothesisId: hypothesisId,
                location: location,
                message: message,
                timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                data: data,
            )
            guard let lineData = try? JSONEncoder().encode(entry),
                  let line = String(data: lineData, encoding: .utf8)
            else { return }
            dbgLogger.info("\(line, privacy: .public)")
        }
    }

    /// `String(describing: NEVPNConnectionError)` 在日志里常为 `NEVPNConnectionError(rawValue: n)`，改用稳定可读标签。
    private static func nevpnConnectionErrorLabel(domain: String, code: Int) -> String? {
        guard domain == NEVPNConnectionErrorDomain, let e = NEVPNConnectionError(rawValue: code) else { return nil }
        switch e {
        case .pluginFailed: return "pluginFailed"
        case .pluginDisabled: return "pluginDisabled"
        case .configurationFailed: return "configurationFailed"
        case .configurationNotFound: return "configurationNotFound"
        case .negotiationFailed: return "negotiationFailed"
        case .authenticationFailed: return "authenticationFailed"
        case .noNetworkAvailable: return "noNetworkAvailable"
        case .unrecoverableNetworkChange: return "unrecoverableNetworkChange"
        case .overslept: return "overslept"
        case .serverAddressResolutionFailed: return "serverAddressResolutionFailed"
        case .serverNotResponding: return "serverNotResponding"
        case .serverDead: return "serverDead"
        case .serverDisconnected: return "serverDisconnected"
        case .clientCertificateInvalid: return "clientCertificateInvalid"
        case .clientCertificateNotYetValid: return "clientCertificateNotYetValid"
        case .clientCertificateExpired: return "clientCertificateExpired"
        case .serverCertificateInvalid: return "serverCertificateInvalid"
        case .serverCertificateNotYetValid: return "serverCertificateNotYetValid"
        case .serverCertificateExpired: return "serverCertificateExpired"
        @unknown default:
            return "raw(\(code))"
        }
    }

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                if let c = notification.object as? NEVPNConnection,
                   c.manager === self.manager
                {
                    self.updateStatusLabel(c.status, connection: c)
                }
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleAppForeground()
            }
        }
        loadPreferences()
    }

    deinit {
        connectingTimeoutWorkItem?.cancel()
        autoReconnectWorkItem?.cancel()
        if let o = observer {
            NotificationCenter.default.removeObserver(o)
        }
        if let o = foregroundObserver {
            NotificationCenter.default.removeObserver(o)
        }
    }

    private func loadPreferences() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    // #region agent log
                    let n = error as NSError
                    Self.AgentDebugLog.log(
                        hypothesisId: "H6",
                        location: "VPNManager.loadPreferences",
                        message: "error",
                        data: [
                            "desc": error.localizedDescription,
                            "domain": n.domain,
                            "code": String(n.code),
                        ],
                    )
                    // #endregion
                    self.statusText = "偏好设置错误"
                    var msg = error.localizedDescription
                    let readWriteFailed = (n.domain == NEVPNErrorDomain && n.code == NEVPNError.configurationReadWriteFailed.rawValue)
                    if readWriteFailed || msg.localizedCaseInsensitiveContains("permission") {
                        msg += "。请确认主 App 与 PacketTunnel 的 entitlements 已包含 packet-tunnel-provider，且 Apple Developer 中两个 App ID 已开启 Network Extensions（Packet Tunnel）并重新下载描述文件/用 Xcode 自动签名。"
                    }
                    self.lastError = msg
                    return
                }
                self.manager = managers?.first as? NETunnelProviderManager
                // #region agent log
                let p = self.manager?.protocolConfiguration as? NETunnelProviderProtocol
                Self.AgentDebugLog.log(
                    hypothesisId: "H6",
                    location: "VPNManager.loadPreferences",
                    message: "loaded",
                    data: [
                        "managerCount": String(managers?.count ?? 0),
                        "hasManager": self.manager == nil ? "false" : "true",
                        "enabled": self.manager?.isEnabled == true ? "true" : "false",
                        "providerBundleId": p?.providerBundleIdentifier ?? "",
                        "serverAddress": p?.serverAddress ?? "",
                        "statusRaw": String(self.manager?.connection.status.rawValue ?? NEVPNStatus.invalid.rawValue),
                    ],
                )
                // #endregion
                self.updateStatusLabel(self.manager?.connection.status ?? .invalid, connection: self.manager?.connection)
            }
        }
    }

    private func cancelConnectingTimeout() {
        connectingTimeoutWorkItem?.cancel()
        connectingTimeoutWorkItem = nil
    }

    private func cancelAutoReconnect() {
        autoReconnectWorkItem?.cancel()
        autoReconnectWorkItem = nil
    }

    private func autoReconnectDelaySeconds() -> TimeInterval {
        let exp = min(autoReconnectAttempt, 5)
        return min(Self.autoReconnectBaseDelaySeconds * pow(2.0, Double(exp)), Self.autoReconnectMaxDelaySeconds)
    }

    private func scheduleAutoReconnectIfNeeded() {
        guard !userRequestedDisconnect else { return }
        guard let params = lastConnectParams else { return }
        guard autoReconnectWorkItem == nil else { return }

        let delay = autoReconnectDelaySeconds()
        statusText = "等待重连（\(Int(ceil(delay)))秒）…"

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.autoReconnectWorkItem = nil
                guard !self.userRequestedDisconnect else { return }
                guard self.neConnectionStatus == .disconnected || self.neConnectionStatus == .invalid else { return }
                self.autoReconnectAttempt += 1
                self.connect(
                    host: params.host,
                    port: params.port,
                    username: params.username,
                    password: params.password,
                    chinaDirect: params.chinaDirect,
                    resetReconnectBackoff: false,
                )
            }
        }
        autoReconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func handleAppForeground() {
        guard !userRequestedDisconnect else { return }
        guard lastConnectParams != nil else { return }
        let status = manager?.connection.status ?? .invalid
        if status == .disconnected || status == .invalid {
            scheduleAutoReconnectIfNeeded()
        }
    }

    private func scheduleConnectingTimeoutIfNeeded() {
        if connectingTimeoutWorkItem != nil { return }
        let seconds = Self.connectingTimeoutSeconds
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.neConnectionStatus == .connecting else { return }
                self.lastError = "连接超时（\(Int(seconds)) 秒），请检查网络或服务器地址"
                self.manager?.connection.stopVPNTunnel()
                if let m = self.manager {
                    self.updateStatusLabel(m.connection.status, connection: m.connection)
                } else {
                    self.updateStatusLabel(.disconnected, connection: nil)
                }
            }
        }
        connectingTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// 与系统「设置 → VPN」相同的数据源：`NEVPNConnection.status`。断开时用 `fetchLastDisconnectError` 拉扩展返回的 NSError（iOS 16+）。
    private func updateStatusLabel(_ s: NEVPNStatus, connection: NEVPNConnection? = nil) {
        neConnectionStatus = s
        if s != .connecting {
            cancelConnectingTimeout()
        }
        let conn = connection ?? manager?.connection
        // #region agent log
        Self.AgentDebugLog.log(
            hypothesisId: "H7",
            location: "VPNManager.updateStatusLabel",
            message: "status",
            data: [
                "statusRaw": String(s.rawValue),
                "hasConnection": conn == nil ? "false" : "true",
            ],
        )
        // #endregion
        switch s {
        case .connected:
            cancelAutoReconnect()
            autoReconnectAttempt = 0
            lastError = nil
            statusText = "已连接"
        case .connecting:
            cancelAutoReconnect()
            scheduleConnectingTimeoutIfNeeded()
            statusText = "连接中…"
        case .disconnecting:
            statusText = "断开中…"
        case .disconnected:
            if !userRequestedDisconnect, lastConnectParams != nil {
                scheduleAutoReconnectIfNeeded()
            } else {
                statusText = "未连接"
            }
            if #available(iOS 16.0, *), let conn {
                conn.fetchLastDisconnectError { err in
                    Task { @MainActor in
                        if let err {
                            let n = err as NSError
                            var diag: [String] = [
                                "domain=\(n.domain)",
                                "code=\(n.code)",
                                "desc=\(err.localizedDescription)",
                            ]
                            if let reason = n.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
                                diag.append("failureReason=\(reason)")
                            }
                            if let u = n.userInfo[NSUnderlyingErrorKey] as? NSError {
                                diag.append("underlying=\(u.domain)(\(u.code)) \(u.localizedDescription)")
                            }
                            if let label = Self.nevpnConnectionErrorLabel(domain: n.domain, code: n.code) {
                                diag.append("NEVPNConnectionError=\(label)")
                            }
                            self.disconnectDiagLog.error("lastDisconnectError \(diag.joined(separator: " "), privacy: .public)")
                            // #region agent log
                            Self.AgentDebugLog.log(
                                hypothesisId: "H7",
                                location: "VPNManager.fetchLastDisconnectError",
                                message: "error",
                                data: [
                                    "desc": err.localizedDescription,
                                    "domain": n.domain,
                                    "code": String(n.code),
                                    "label": Self.nevpnConnectionErrorLabel(domain: n.domain, code: n.code) ?? "",
                                ],
                            )
                            // #endregion
                            var parts: [String] = [err.localizedDescription]
                            if let reason = n.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
                                parts.append(reason)
                            }
                            // code==12：NEVPNConnectionError.pluginFailed；系统文案常为 internal error，需单独说明含义。
                            if n.domain == NEVPNConnectionErrorDomain,
                               n.code == NEVPNConnectionError.pluginFailed.rawValue
                            {
                                parts.append(
                                    "（扩展 pluginFailed：多为隧道网络设置失败、协议握手失败或扩展进程退出；请在 Mac 控制台查看 PacketTunnel 或子系统 com.newworld.nwvpn.ios；可先关闭「国内直连」再试。）"
                                )
                            }
                            self.lastError = parts.joined(separator: " — ")
                        } else if self.lastError == nil || self.lastError?.isEmpty == true {
                            self.lastError = "隧道已断开（可先关闭「国内直连」重试）"
                        }
                    }
                }
            } else if lastError == nil || lastError?.isEmpty == true {
                lastError = "隧道已断开（可先关闭「国内直连」重试）"
            }
        case .invalid:
            statusText = "未配置或需重新授权"
        case .reasserting:
            statusText = "重连中…"
        @unknown default:
            statusText = "未知"
        }
    }

    private func beginConnectFlow() -> Bool {
        connectFlowLock.lock()
        defer { connectFlowLock.unlock() }
        if connectFlowActive { return false }
        connectFlowActive = true
        return true
    }

    private func endConnectFlow() {
        connectFlowLock.lock()
        connectFlowActive = false
        connectFlowLock.unlock()
        tunnelConfigurationBusy = false
    }

    private static func buildProviderConfiguration(username: String, password: String, chinaDirect: Bool) -> [String: NSObject] {
        var cfg: [String: NSObject] = [
            "china_direct_enabled": NSNumber(value: chinaDirect),
        ]
        if !username.isEmpty {
            cfg["username"] = username as NSString
            cfg["password"] = password as NSString
        }
        return cfg
    }

    private static func providerConfigEqual(_ a: [String: NSObject], _ b: [String: NSObject]) -> Bool {
        guard a.count == b.count else { return false }
        for (k, v) in b {
            guard let av = a[k] else { return false }
            if !av.isEqual(v) { return false }
        }
        return true
    }

    /// 已与系统里已保存的配置一致时，可避免反复 `saveToPreferences`（会触发 nehelper 多次 Clear/Add，易与扩展启动竞态）。
    private func savedConfigurationMatches(
        manager m: NETunnelProviderManager,
        addr: String,
        username: String,
        password: String,
        chinaDirect: Bool,
    ) -> Bool {
        guard let p = m.protocolConfiguration as? NETunnelProviderProtocol else { return false }
        guard p.providerBundleIdentifier == extensionBundleId, p.serverAddress == addr else { return false }
        let want = Self.buildProviderConfiguration(username: username, password: password, chinaDirect: chinaDirect)
        let have = (p.providerConfiguration as? [String: NSObject]) ?? [:]
        return Self.providerConfigEqual(have, want)
    }

    func connect(
        host: String,
        port: String,
        username: String,
        password: String,
        chinaDirect: Bool,
        resetReconnectBackoff: Bool = true,
    ) {
        guard beginConnectFlow() else { return }
        userRequestedDisconnect = false
        cancelAutoReconnect()
        if resetReconnectBackoff {
            autoReconnectAttempt = 0
        }
        lastConnectParams = ConnectParams(
            host: host.trimmingCharacters(in: .whitespaces),
            port: port.trimmingCharacters(in: .whitespaces),
            username: username,
            password: password,
            chinaDirect: chinaDirect,
        )
        lastError = nil
        tunnelConfigurationBusy = true
        let addr = "\(host.trimmingCharacters(in: .whitespaces)):\(port.trimmingCharacters(in: .whitespaces))"
        // #region agent log
        Self.AgentDebugLog.log(
            hypothesisId: "H6",
            location: "VPNManager.connect",
            message: "begin",
            data: [
                "addr": addr,
                "chinaDirect": String(chinaDirect),
                "hasUsername": username.isEmpty ? "false" : "true",
            ],
        )
        // #endregion

        /// completion 链路内全程强引用 `self`，确保 `beginConnectFlow` 后任一出口都能 `endConnectFlow`，避免僵尸门闩。
        NETunnelProviderManager.loadAllFromPreferences { [self] managers, err in
            Task { @MainActor [self] in
                if let err {
                    // #region agent log
                    let n = err as NSError
                    Self.AgentDebugLog.log(
                        hypothesisId: "H6",
                        location: "VPNManager.connect.loadAllFromPreferences",
                        message: "error",
                        data: [
                            "desc": err.localizedDescription,
                            "domain": n.domain,
                            "code": String(n.code),
                        ],
                    )
                    // #endregion
                    self.lastError = err.localizedDescription
                    self.endConnectFlow()
                    return
                }

                let m: NETunnelProviderManager
                if let existing = managers?.first as? NETunnelProviderManager {
                    m = existing
                } else {
                    m = NETunnelProviderManager()
                }

                let wantCfg = Self.buildProviderConfiguration(username: username, password: password, chinaDirect: chinaDirect)
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = self.extensionBundleId
                proto.serverAddress = addr
                proto.providerConfiguration = wantCfg
                let hasExisting = (managers?.first as? NETunnelProviderManager) != nil
                let configMatches = self.savedConfigurationMatches(manager: m, addr: addr, username: username, password: password, chinaDirect: chinaDirect)
                // #region agent log
                Self.AgentDebugLog.log(
                    hypothesisId: "H6",
                    location: "VPNManager.connect",
                    message: "manager_prepared",
                    data: [
                        "managerCount": String(managers?.count ?? 0),
                        "hasExisting": String(hasExisting),
                        "configMatches": String(configMatches),
                        "enabled": String(m.isEnabled),
                        "providerBundleId": proto.providerBundleIdentifier ?? "",
                        "serverAddress": proto.serverAddress ?? "",
                    ],
                )
                // #endregion

                /// 已与磁盘偏好一致：直接启动，不写偏好（减少对 nehelper / 扩展的瞬时压力）。
                if hasExisting, configMatches, m.isEnabled
                {
                    self.manager = m
                    defer { self.endConnectFlow() }
                    do {
                        try m.connection.startVPNTunnel()
                        // #region agent log
                        Self.AgentDebugLog.log(
                            hypothesisId: "H6",
                            location: "VPNManager.connect.startVPNTunnel",
                            message: "called_existing_config",
                            data: ["statusRaw": String(m.connection.status.rawValue)],
                        )
                        // #endregion
                        self.updateStatusLabel(m.connection.status, connection: m.connection)
                    } catch {
                        // #region agent log
                        let n = error as NSError
                        Self.AgentDebugLog.log(
                            hypothesisId: "H6",
                            location: "VPNManager.connect.startVPNTunnel",
                            message: "threw_existing_config",
                            data: [
                                "desc": error.localizedDescription,
                                "domain": n.domain,
                                "code": String(n.code),
                            ],
                        )
                        // #endregion
                        self.lastError = error.localizedDescription
                    }
                    return
                }
                m.protocolConfiguration = proto
                m.localizedDescription = "NewWorld VPN"
                m.isEnabled = true

                m.saveToPreferences { [self] saveErr in
                    Task { @MainActor [self] in
                        if let saveErr {
                            // #region agent log
                            let n = saveErr as NSError
                            Self.AgentDebugLog.log(
                                hypothesisId: "H6",
                                location: "VPNManager.connect.saveToPreferences",
                                message: "error",
                                data: [
                                    "desc": saveErr.localizedDescription,
                                    "domain": n.domain,
                                    "code": String(n.code),
                                ],
                            )
                            // #endregion
                            self.lastError = saveErr.localizedDescription
                            self.endConnectFlow()
                            return
                        }
                        m.loadFromPreferences { [self] loadErr in
                            Task { @MainActor [self] in
                                defer { self.endConnectFlow() }
                                if let loadErr {
                                    // #region agent log
                                    let n = loadErr as NSError
                                    Self.AgentDebugLog.log(
                                        hypothesisId: "H6",
                                        location: "VPNManager.connect.loadFromPreferences",
                                        message: "error",
                                        data: [
                                            "desc": loadErr.localizedDescription,
                                            "domain": n.domain,
                                            "code": String(n.code),
                                        ],
                                    )
                                    // #endregion
                                    self.lastError = loadErr.localizedDescription
                                    return
                                }
                                self.manager = m
                                do {
                                    try m.connection.startVPNTunnel()
                                    // #region agent log
                                    Self.AgentDebugLog.log(
                                        hypothesisId: "H6",
                                        location: "VPNManager.connect.startVPNTunnel",
                                        message: "called_after_save",
                                        data: ["statusRaw": String(m.connection.status.rawValue)],
                                    )
                                    // #endregion
                                    self.updateStatusLabel(m.connection.status, connection: m.connection)
                                } catch {
                                    // #region agent log
                                    let n = error as NSError
                                    Self.AgentDebugLog.log(
                                        hypothesisId: "H6",
                                        location: "VPNManager.connect.startVPNTunnel",
                                        message: "threw_after_save",
                                        data: [
                                            "desc": error.localizedDescription,
                                            "domain": n.domain,
                                            "code": String(n.code),
                                        ],
                                    )
                                    // #endregion
                                    self.lastError = error.localizedDescription
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func disconnect() {
        userRequestedDisconnect = true
        cancelAutoReconnect()
        cancelConnectingTimeout()
        manager?.connection.stopVPNTunnel()
        if let m = manager {
            updateStatusLabel(m.connection.status, connection: m.connection)
        }
    }
}
