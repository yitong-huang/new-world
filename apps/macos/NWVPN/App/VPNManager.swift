import Foundation
import NetworkExtension
import Darwin

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
            Task { @MainActor in
                if let c = notification.object as? NEVPNConnection,
                   let mgr = self.manager, c.manager === mgr
                {
                    self.updateStatusLabel(c.status, connection: c)
                } else if notification.object == nil, let mgr = self.manager {
                    self.updateStatusLabel(mgr.connection.status, connection: mgr.connection)
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
                self.updateStatusLabel(
                    self.manager?.connection.status ?? .invalid,
                    connection: self.manager?.connection,
                )
            }
        }
    }

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
            if #available(macOS 13.0, *), let conn {
                conn.fetchLastDisconnectError { err in
                    Task { @MainActor in
                        if let err {
                            let n = err as NSError
                            var parts: [String] = [err.localizedDescription]
                            if let reason = n.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
                                parts.append(reason)
                            }
                            self.lastError = parts.joined(separator: " — ")
                        }
                    }
                }
            }
        case .invalid:
            statusText = "未配置或需重新授权"
        case .reasserting:
            statusText = "重连中…"
        @unknown default:
            statusText = "未知"
        }
    }

    func connect(host: String, port: String, username: String, password: String) {
        lastError = nil
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedPort = port.trimmingCharacters(in: .whitespaces)
        let resolvedHost = Self.resolveIPv4Host(trimmedHost) ?? trimmedHost
        let addr = "\(resolvedHost):\(trimmedPort)"

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
                // 不把用户名密码写入偏好（避免 NE XPC / NSSecureCoding 解码告警与损坏 blob）；连接时见 `startVPNTunnel(options:)`。
                proto.providerConfiguration = nil

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
                                    let tunnelOpts: [String: NSObject]?
                                    if username.isEmpty {
                                        tunnelOpts = nil
                                    } else {
                                        tunnelOpts = [
                                            "username": username as NSString,
                                            "password": password as NSString,
                                        ]
                                    }
                                    try m.connection.startVPNTunnel(options: tunnelOpts)
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

    private static func resolveIPv4Host(_ host: String) -> String? {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil,
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let info = cursor {
            if info.pointee.ai_family == AF_INET,
               let addr = info.pointee.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0 })
            {
                var ip = addr.pointee.sin_addr
                if inet_ntop(AF_INET, &ip, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    return String(cString: buffer)
                }
            }
            cursor = info.pointee.ai_next
        }
        return nil
    }
}
