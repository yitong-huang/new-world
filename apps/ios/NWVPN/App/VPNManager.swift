import Foundation
import NetworkExtension

@MainActor
final class VPNManager: ObservableObject {
    @Published private(set) var statusText = "加载中…"
    @Published var lastError: String?
    /// 正在 save/load 偏好并拉起隧道时设为 true，避免连点触发多路 NE 并发（Console 会看到扩展、保存配置各出现多份）。
    @Published private(set) var tunnelConfigurationBusy = false

    /// 同步门闸：`@Published` 可能在同一 runloop 内尚未刷新，连点仍会进入 connect；用锁保证整段流程互斥。
    private let connectFlowLock = NSLock()
    private var connectFlowActive = false

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    /// 与 `project.yml` 中扩展的 `PRODUCT_BUNDLE_IDENTIFIER` 一致。
    private let extensionBundleId = "com.newworld.NWVPNiOS.PacketTunnel"

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
        loadPreferences()
    }

    deinit {
        if let o = observer {
            NotificationCenter.default.removeObserver(o)
        }
    }

    private func loadPreferences() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                    self.statusText = "偏好设置错误"
                    return
                }
                self.manager = managers?.first as? NETunnelProviderManager
                self.updateStatusLabel(self.manager?.connection.status ?? .invalid, connection: self.manager?.connection)
            }
        }
    }

    /// 与系统「设置 → VPN」相同的数据源：`NEVPNConnection.status`。断开时用 `fetchLastDisconnectError` 拉扩展返回的 NSError（iOS 16+）。
    private func updateStatusLabel(_ s: NEVPNStatus, connection: NEVPNConnection? = nil) {
        let conn = connection ?? manager?.connection
        switch s {
        case .connected:
            lastError = nil
            statusText = "已连接"
        case .connecting:
            statusText = "连接中…"
        case .disconnecting:
            statusText = "断开中…"
        case .disconnected:
            statusText = "未连接"
            if #available(iOS 16.0, *), let conn {
                conn.fetchLastDisconnectError { err in
                    Task { @MainActor in
                        if let err {
                            let n = err as NSError
                            var parts: [String] = [err.localizedDescription]
                            if let reason = n.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
                                parts.append(reason)
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

    func connect(host: String, port: String, username: String, password: String, chinaDirect: Bool) {
        guard beginConnectFlow() else { return }
        lastError = nil
        tunnelConfigurationBusy = true
        let addr = "\(host.trimmingCharacters(in: .whitespaces)):\(port.trimmingCharacters(in: .whitespaces))"

        /// completion 链路内全程强引用 `self`，确保 `beginConnectFlow` 后任一出口都能 `endConnectFlow`，避免僵尸门闩。
        NETunnelProviderManager.loadAllFromPreferences { [self] managers, err in
            Task { @MainActor [self] in
                if let err {
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

                /// 已与磁盘偏好一致：直接启动，不写偏好（减少对 nehelper / 扩展的瞬时压力）。
                if managers?.first as? NETunnelProviderManager != nil,
                   self.savedConfigurationMatches(manager: m, addr: addr, username: username, password: password, chinaDirect: chinaDirect)
                {
                    self.manager = m
                    defer { self.endConnectFlow() }
                    do {
                        try m.connection.startVPNTunnel()
                        self.updateStatusLabel(m.connection.status, connection: m.connection)
                    } catch {
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
                            self.lastError = saveErr.localizedDescription
                            self.endConnectFlow()
                            return
                        }
                        m.loadFromPreferences { [self] loadErr in
                            Task { @MainActor [self] in
                                defer { self.endConnectFlow() }
                                if let loadErr {
                                    self.lastError = loadErr.localizedDescription
                                    return
                                }
                                self.manager = m
                                do {
                                    try m.connection.startVPNTunnel()
                                    self.updateStatusLabel(m.connection.status, connection: m.connection)
                                } catch {
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
        manager?.connection.stopVPNTunnel()
        if let m = manager {
            updateStatusLabel(m.connection.status, connection: m.connection)
        }
    }
}
