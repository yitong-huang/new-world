import SwiftUI
import UIKit

private enum NodePrefs {
    /// 与 macOS 客户端同一 key，便于将来 Handoff/描述一致；仍按各 App 沙盒独立存储。
    static let selectedHostKey = "NewWorldVPN.node.selectedHost"
}

struct ContentView: View {
    @EnvironmentObject private var vpn: VPNManager
    @State private var serverNodes: [VPNServerEntry] = []
    @AppStorage(NodePrefs.selectedHostKey) private var selectedServerHost = ""

    @State private var username = ""
    @State private var password = ""
    @State private var chinaDirect = false
    @State private var lastConnectTap = Date(timeIntervalSince1970: 0)

    /// 未连接/未配置：红色；已连接：蓝色；其余（连接中等）：次要色。
    private var statusDisplayColor: Color {
        switch vpn.neConnectionStatus {
        case .connected:
            return .blue
        case .disconnected, .invalid:
            return .red
        default:
            return .secondary
        }
    }

    private var statusRowIsTappable: Bool {
        if vpn.tunnelConfigurationBusy { return false }
        if vpn.statusText == "加载中…" || vpn.statusText == "偏好设置错误" { return false }
        switch vpn.neConnectionStatus {
        case .connected:
            return true
        case .disconnected, .invalid:
            return !serverNodes.isEmpty
        default:
            return false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    if serverNodes.isEmpty {
                        Text("未加载节点列表（请确认已打包 configs/servers）")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("节点", selection: $selectedServerHost) {
                            ForEach(serverNodes) { node in
                                Text(node.displayName).tag(node.host)
                            }
                        }
                    }
                }

                Section("认证（可选）") {
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    SecureField("密码", text: $password)
                }

                Section("分流") {
                    Toggle("仅墙外走隧道（国内直连）", isOn: $chinaDirect)
                    Text("开启后会使用扩展内置的 china_ipv4/extra_direct_ipv4 规则。若连接失败，可先关闭此项做排查。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("状态") {
                    // 状态与错误放在同一 list row，避免分组列表「两行之间」自带缩进分割线（看起来像只有一半宽）。
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            handleStatusTap()
                        } label: {
                            HStack {
                                Spacer(minLength: 0)
                                Text(vpn.statusText)
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(statusDisplayColor)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!statusRowIsTappable)

                        if let err = vpn.lastError, !err.isEmpty {
                            Rectangle()
                                .fill(Color(uiColor: .separator))
                                .frame(height: 1 / max(UIScreen.main.scale, 2))
                                .frame(maxWidth: .infinity)
                                .padding(.top, 12)
                            Text(err)
                                .foregroundStyle(.red)
                                .font(.caption)
                                .padding(.top, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
                }
            }
            .navigationTitle("NewWorld VPN")
            .onAppear {
                serverNodes = VPNServerCatalog.loadEntries()
                normalizeSelectedServerHost()
            }
        }
    }

    private func handleStatusTap() {
        let now = Date()
        guard now.timeIntervalSince(lastConnectTap) > 0.45 else { return }
        lastConnectTap = now
        switch vpn.neConnectionStatus {
        case .connected:
            vpn.disconnect()
        case .disconnected, .invalid:
            performConnect()
        default:
            break
        }
    }

    private func performConnect() {
        serverNodes = VPNServerCatalog.loadEntries()
        normalizeSelectedServerHost()
        let addr = VPNServerCatalog.resolveServerAddress(selectedHost: selectedServerHost)
        guard let split = splitHostPort(addr) else {
            vpn.lastError = "服务器地址无效"
            return
        }
        vpn.connect(host: split.host, port: split.port, username: username, password: password, chinaDirect: chinaDirect)
    }

    private func normalizeSelectedServerHost() {
        serverNodes = VPNServerCatalog.loadEntries()
        let key = VPNServerCatalog.normalizeHostLookup(selectedServerHost)
        if let match = serverNodes.first(where: { VPNServerCatalog.normalizeHostLookup($0.host) == key }) {
            if selectedServerHost != match.host {
                selectedServerHost = match.host
            }
            return
        }
        if let first = serverNodes.first {
            selectedServerHost = first.host
        }
    }

    private func splitHostPort(_ addr: String) -> (host: String, port: String)? {
        let t = addr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let r = t.range(of: ":", options: .literal) {
            let h = String(t[..<r.lowerBound])
            let p = String(t[r.upperBound...])
            if !h.isEmpty, !p.isEmpty { return (h, p) }
        }
        return (t, "8443")
    }
}

#Preview {
    ContentView()
        .environmentObject(VPNManager())
}
