import SwiftUI

private enum AuthPrefs {
    static let usernameKey = "NewWorldVPN.auth.username"
    static let passwordKey = "NewWorldVPN.auth.password"
    static let includeKey = "NewWorldVPN.auth.includeWhenConnecting"
}

struct ContentView: View {
    @EnvironmentObject private var tunnel: TunnelController

    @State private var username = ""
    @State private var password = ""
    /// 连接时是否向 nw-client 传入 -auth-file（可在对话框内勾选）
    @State private var includeAuthWhenConnecting = true

    @State private var useSplitDefault = true
    @State private var useChinaDirect = false
    @State private var chinaRoutesPath = ""
    @State private var extraDirectRoutesPath = ""

    private let circleSize: CGFloat = 128
    /// 与 `Toggle(.checkbox)` 左侧控件大致同宽，使「未配置」与「韩国」等标签文字左缘对齐
    private let checkboxColumnWidth: CGFloat = 22
    /// 区块之间的留白（与 Divider 一起使用，避免只靠 padding 在 ScrollView 里被拉伸吃掉）
    private let sectionBlockVerticalPadding: CGFloat = 20

    private var connectionButtonTitle: String {
        tunnel.isConnected ? "已连接" : "未连接"
    }

    /// 目前仅韩国节点，固定使用该地址
    private var serverAddress: String {
        VPNNode.korea.serverAddress
    }

    private var hasSavedCredentials: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // 不用 ScrollView 占满剩余高度：在 MenuBarExtra 里 ScrollView 常会纵向拉伸子视图，
            // 导致「大块 padding」在布局上被摊薄，肉眼几乎看不出分区。
            ScrollView {
                settingsColumn
                    .padding(.horizontal, 16)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 强制按内容内在高度布局，不把多出来的 ScrollView 高度均摊进子视图间隙
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 420, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 16) {
                if let err = tunnel.lastError, !err.isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                }

                HStack {
                    Spacer(minLength: 0)
                    Button {
                        Task {
                            if tunnel.isConnected {
                                await tunnel.disconnect()
                            } else {
                                let u: String
                                let p: String
                                if includeAuthWhenConnecting && hasSavedCredentials {
                                    u = username
                                    p = password
                                } else {
                                    u = ""
                                    p = ""
                                }
                                await tunnel.connect(
                                    serverAddress: serverAddress,
                                    username: u,
                                    password: p,
                                    caCertPath: resolvedCaPath(),
                                    nwClientPath: resolvedNwClientPath(),
                                    splitDefault: useSplitDefault,
                                    chinaDirect: useChinaDirect,
                                    chinaRoutesPath: chinaRoutesPath,
                                    extraDirectRoutesPath: extraDirectRoutesPath,
                                )
                            }
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(tunnel.isConnected ? Color.blue.opacity(0.22) : Color.red.opacity(0.22))
                                .frame(width: circleSize + 28, height: circleSize + 28)
                                .blur(radius: 10)

                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: tunnel.isConnected
                                            ? [Color(red: 0.2, green: 0.45, blue: 0.95), Color(red: 0.1, green: 0.35, blue: 0.88)]
                                            : [Color(red: 0.95, green: 0.28, blue: 0.32), Color(red: 0.85, green: 0.18, blue: 0.24)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: circleSize, height: circleSize)
                                .shadow(color: (tunnel.isConnected ? Color.blue : Color.red).opacity(0.35), radius: 18, y: 6)
                                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)

                            Text(connectionButtonTitle)
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .minimumScaleFactor(0.75)
                                .lineLimit(1)
                        }
                        .frame(width: circleSize + 28, height: circleSize + 28)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(tunnel.isConnected ? "点击断开" : "点击连接")
                    Spacer(minLength: 0)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 400)
        .background(
            LinearGradient(
                colors: [
                    Color(white: 0.995),
                    Color(red: 0.99, green: 0.965, blue: 0.985),
                    Color(red: 0.975, green: 0.955, blue: 0.99),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onAppear {
            loadAuthFromDefaults()
        }
        .onChange(of: useChinaDirect) { enabled in
            guard enabled else { return }
            if chinaRoutesPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let p = defaultBundledRoutesPath(name: "china_ipv4", ext: "txt") {
                chinaRoutesPath = p
            }
            if extraDirectRoutesPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let e = defaultBundledRoutesPath(name: "extra_direct_ipv4", ext: "txt") {
                extraDirectRoutesPath = e
            }
        }
    }

    /// 设置项主列（节点 / 认证 / 分流）
    private var settingsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            nodeSection

            sectionSeparator

            VStack(alignment: .leading, spacing: 8) {
                panelSectionTitle("认证")
                authTriggerCard
                    .padding(12)
                    .background(panelCardBackground)
            }

            sectionSeparator

            VStack(alignment: .leading, spacing: 10) {
                panelSectionTitle("分流")
                VStack(alignment: .leading, spacing: 12) {
                    splitTrafficToggle(title: "全流量（-split-default）", isOn: $useSplitDefault)
                    splitTrafficToggle(title: "国内 IP 直连（-china-routes）", isOn: $useChinaDirect)

                    if useChinaDirect {
                        TextField("", text: $chinaRoutesPath, prompt: Text("china_ipv4.txt 路径"))
                            .textFieldStyle(.roundedBorder)
                        TextField("", text: $extraDirectRoutesPath, prompt: Text("extra_direct_ipv4.txt（可选）"))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(12)
                .background(panelCardBackground)
            }
        }
    }

    private var sectionSeparator: some View {
        Divider()
            .padding(.vertical, sectionBlockVerticalPadding)
    }

    /// 分流选项：标签字体与样式一致
    private func splitTrafficToggle(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.body)
        }
        .toggleStyle(.checkbox)
    }

    /// 节点卡片：浅灰说明「节点」+ 与分流一致的韩国勾选行
    private var nodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("节点")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.85))
            nodeDisplayRow
        }
        .padding(12)
        .background(panelCardBackground)
    }

    /// 与「分流」勾选行同一控件样式，保证左侧勾选框与文字对齐
    private var nodeDisplayRow: some View {
        Toggle(isOn: .constant(true)) {
            Text("韩国")
                .font(.body)
        }
        .toggleStyle(.checkbox)
        .allowsHitTesting(false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var authStatusLine: String {
        if hasSavedCredentials {
            return includeAuthWhenConnecting
                ? "已保存 · 连接时将带上认证"
                : "已保存 · 连接时不传认证"
        }
        return "未配置"
    }

    private var authTriggerCard: some View {
        Button {
            AuthFloatingPanel.present(
                username: username,
                password: password,
                includeWhenConnecting: includeAuthWhenConnecting,
            ) { u, p, include in
                username = u
                password = p
                includeAuthWhenConnecting = include
                saveAuthToDefaults()
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Color.clear
                    .frame(width: checkboxColumnWidth, height: 1)
                Text(authStatusLine)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("e", modifiers: [.command])
    }

    private func panelSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }

    private var panelCardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.thinMaterial)
    }

    private func loadAuthFromDefaults() {
        let d = UserDefaults.standard
        username = d.string(forKey: AuthPrefs.usernameKey) ?? ""
        password = d.string(forKey: AuthPrefs.passwordKey) ?? ""
        if d.object(forKey: AuthPrefs.includeKey) != nil {
            includeAuthWhenConnecting = d.bool(forKey: AuthPrefs.includeKey)
        } else {
            includeAuthWhenConnecting = true
        }
    }

    private func saveAuthToDefaults() {
        let d = UserDefaults.standard
        d.set(username, forKey: AuthPrefs.usernameKey)
        d.set(password, forKey: AuthPrefs.passwordKey)
        d.set(includeAuthWhenConnecting, forKey: AuthPrefs.includeKey)
    }

    private func resolvedNwClientPath() -> String {
        defaultBundledNwClient() ?? ""
    }

    private func resolvedCaPath() -> String {
        defaultBundledCa() ?? ""
    }

    private func defaultBundledNwClient() -> String? {
        if let url = Bundle.main.url(forResource: "nw-client", withExtension: nil) {
            let p = url.path
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private func defaultBundledCa() -> String? {
        if let url = Bundle.main.url(forResource: "server", withExtension: "crt") {
            let p = url.path
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// 与构建脚本复制到 `Resources` 的路由表同名（留空连接时 `TunnelController` 也会再回退一次）。
    private func defaultBundledRoutesPath(name: String, ext: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
        let p = url.path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }
}

#Preview {
    ContentView()
        .environmentObject(TunnelController())
        .frame(width: 420, height: 560)
}
