import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var vpn: VPNManager
    @State private var host = "new-world-kr-01.2fish.com.cn"
    @State private var port = "8443"
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section("服务器") {
                TextField("主机", text: $host)
                TextField("端口", text: $port)
            }
            Section("认证（可选）") {
                TextField("用户名", text: $username)
                SecureField("密码", text: $password)
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
            HStack {
                Button("连接") {
                    vpn.connect(host: host, port: port, username: username, password: password)
                }
                .keyboardShortcut(.return, modifiers: [])
                Button("断开") {
                    vpn.disconnect()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding()
        .frame(minWidth: 380)
    }
}

#Preview {
    ContentView()
        .environmentObject(VPNManager())
}
