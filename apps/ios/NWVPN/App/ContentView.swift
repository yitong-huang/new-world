import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var vpn: VPNManager
    @State private var host = "new-world-kr-01.2fish.com.cn"
    @State private var port = "8443"
    @State private var username = ""
    @State private var password = ""
    @State private var chinaDirect = false
    @State private var lastConnectTap = Date(timeIntervalSince1970: 0)

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("主机", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
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
                    Text(vpn.statusText)
                        .foregroundStyle(.secondary)
                    if let err = vpn.lastError, !err.isEmpty {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button("连接") {
                        let now = Date()
                        guard now.timeIntervalSince(lastConnectTap) > 0.45 else { return }
                        lastConnectTap = now
                        vpn.connect(host: host, port: port, username: username, password: password, chinaDirect: chinaDirect)
                    }
                    .disabled(vpn.tunnelConfigurationBusy)
                    Button("断开", role: .destructive) {
                        vpn.disconnect()
                    }
                }
            }
            .navigationTitle("NewWorld VPN")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(VPNManager())
}
