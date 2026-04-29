import Foundation
import NetworkExtension

/// 主应用：通过 `NETunnelProviderManager` 启动内嵌的 Packet Tunnel 扩展。
@MainActor
final class VPNManager: ObservableObject {
    @Published private(set) var statusText = "加载中…"
    @Published var lastError: String?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    /// 与 `project.yml` 中扩展的 `PRODUCT_BUNDLE_IDENTIFIER` 一致。
    private let extensionBundleId = "com.newworld.NWVPN.PacketTunnel"

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            guard let self else { return }
            if let c = notification.object as? NEVPNConnection,
               c.manager === self.manager
            {
                self.updateStatusLabel(c.status)
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
                self.updateStatusLabel(self.manager?.connection.status ?? .invalid)
            }
        }
    }

    private func updateStatusLabel(_ s: NEVPNStatus) {
        lastError = nil
        switch s {
        case .connected: statusText = "已连接"
        case .connecting: statusText = "连接中…"
        case .disconnecting: statusText = "断开中…"
        case .disconnected: statusText = "未连接"
        case .invalid: statusText = "未配置或需重新授权"
        case .reasserting: statusText = "重连中…"
        @unknown default: statusText = "未知"
        }
    }

    func connect(host: String, port: String, username: String, password: String) {
        lastError = nil
        let addr = "\(host.trimmingCharacters(in: .whitespaces)):\(port.trimmingCharacters(in: .whitespaces))"

        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, err in
            Task { @MainActor in
                guard let self else { return }
                if let err {
                    self.lastError = err.localizedDescription
                    return
                }
                let m: NETunnelProviderManager
                if let existing = managers?.first as? NETunnelProviderManager {
                    m = existing
                } else {
                    m = NETunnelProviderManager()
                }

                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = self.extensionBundleId
                proto.serverAddress = addr
                var cfg: [String: NSObject] = [:]
                if !username.isEmpty {
                    cfg["username"] = username as NSString
                    cfg["password"] = password as NSString
                }
                proto.providerConfiguration = cfg.isEmpty ? nil : cfg

                m.protocolConfiguration = proto
                m.localizedDescription = "NewWorld VPN"
                m.isEnabled = true

                m.saveToPreferences { saveErr in
                    Task { @MainActor in
                        if let saveErr {
                            self.lastError = saveErr.localizedDescription
                            return
                        }
                        m.loadFromPreferences { loadErr in
                            Task { @MainActor in
                                if let loadErr {
                                    self.lastError = loadErr.localizedDescription
                                    return
                                }
                                self.manager = m
                                do {
                                    try m.connection.startVPNTunnel()
                                    self.updateStatusLabel(m.connection.status)
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
            updateStatusLabel(m.connection.status)
        }
    }
}
