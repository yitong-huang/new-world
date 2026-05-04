import Foundation

@MainActor
final class TunnelController: ObservableObject {
    @Published private(set) var statusText = "未连接"
    @Published var lastError: String?
    @Published private(set) var isConnected = false

    private var xpc: NSXPCConnection?

    private static let machServiceName = "com.newworld.NewWorldVPN.helper"

    private func makeConnection() -> NSXPCConnection {
        let c = NSXPCConnection(
            machServiceName: Self.machServiceName,
            options: [.privileged],
        )
        c.remoteObjectInterface = configuredRemoteInterface()
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.xpc = nil
            }
        }
        c.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.xpc = nil
                self?.statusText = "连接中断"
                self?.isConnected = false
            }
        }
        c.resume()
        return c
    }

    private func configuredRemoteInterface() -> NSXPCInterface {
        NSXPCInterface(with: TunnelHelperProtocol.self)
    }

    private func remoteProxy() -> TunnelHelperProtocol? {
        if xpc == nil {
            xpc = makeConnection()
        }
        guard let xpc else { return nil }
        return xpc.remoteObjectProxyWithErrorHandler { err in
            Task { @MainActor in
                self.lastError = err.localizedDescription
            }
        } as? TunnelHelperProtocol
    }

    func refreshStatus() {
        remoteProxy()?.status { running, errStr in
            Task { @MainActor in
                self.isConnected = running
                if running {
                    self.statusText = "已连接"
                } else if !errStr.isEmpty {
                    self.lastError = errStr
                }
            }
        }
    }

    /// `serverAddress` 为 `host:port`，例如 `vpn.example.com:8443`（TLS ServerName 仍取主机名）。
    func connect(
        serverAddress: String,
        username: String,
        password: String,
        caCertPath: String,
        nwClientPath: String,
        splitDefault: Bool,
        chinaDirect: Bool,
        chinaRoutesPath: String,
        extraDirectRoutesPath: String,
    ) async {
        lastError = nil
        statusText = "正在注册助手…"

        do {
            try await HelperInstaller.registerDaemonIfNeeded()
        } catch {
            let detail = error.localizedDescription
            let hint: String
            let lower = detail.lowercased()
            if lower.contains("codesign") || lower.contains("code signing") || detail.contains("-67056") {
                hint = "这通常由**应用未正确代码签名**引起（例如用 CODE_SIGNING_ALLOWED=NO 打包且未做 ad-hoc 签名）。请从源码重新执行打包脚本生成安装包，或在本机用 Xcode Archive + 有效证书签名后再安装。仅「系统设置 → 登录项/后台」无法绕过签名校验。"
            } else {
                hint = "请在系统设置 → 通用 → 登录项与扩展（或「登录项」）中允许 NewWorldVPN 的后台项后重试。"
            }
            lastError = "注册特权助手失败：\(detail)。\(hint)"
            statusText = "未连接"
            return
        }

        let exe = (nwClientPath as NSString).standardizingPath
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            lastError = "找不到可执行的 nw-client：\(exe)"
            statusText = "未连接"
            return
        }

        let ca = (caCertPath as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: ca) else {
            lastError = "找不到 CA 证书：\(ca)"
            statusText = "未连接"
            return
        }

        let resolvedChina: String
        let resolvedExtra: String
        if chinaDirect {
            var cr = (chinaRoutesPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).standardizingPath
            if cr.isEmpty {
                cr = Self.bundledRoutesPath(name: "china_ipv4", ext: "txt") ?? ""
            }
            guard !cr.isEmpty, FileManager.default.fileExists(atPath: cr) else {
                lastError = "国内直连需要 china 路由表：请在界面填写有效路径，或确保构建时已把 configs/china_ipv4.txt 复制进应用资源。"
                statusText = "未连接"
                return
            }
            var er = (extraDirectRoutesPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).standardizingPath
            if er.isEmpty {
                er = Self.bundledRoutesPath(name: "extra_direct_ipv4", ext: "txt") ?? ""
            }
            if !er.isEmpty, !FileManager.default.fileExists(atPath: er) {
                lastError = "补丁路由表路径不存在"
                statusText = "未连接"
                return
            }
            resolvedChina = cr
            resolvedExtra = er
        } else {
            resolvedChina = ""
            resolvedExtra = ""
        }

        let serverAddr = serverAddress.trimmingCharacters(in: .whitespaces)
        guard !serverAddr.isEmpty else {
            lastError = "服务器地址为空"
            statusText = "未连接"
            return
        }

        var argv: [String] = [
            "-server", serverAddr,
            "-cacert", ca,
        ]

        let splitOn = splitDefault || chinaDirect
        if splitOn {
            argv.append("-split-default")
        }
        if chinaDirect {
            argv.append(contentsOf: ["-china-routes", resolvedChina])
            if !resolvedExtra.isEmpty {
                argv.append(contentsOf: ["-extra-direct-routes", resolvedExtra])
            }
        }

        var authPath: String?
        if !username.isEmpty {
            let auth: [String: String] = [
                "username": username,
                "password": password,
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: auth, options: [])
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("newworldvpn-auth-\(UUID().uuidString).json")
                try data.write(to: url, options: [.atomic])
                authPath = url.path
                argv.append(contentsOf: ["-auth-file", url.path])
            } catch {
                lastError = "写入临时认证文件失败：\(error.localizedDescription)"
                statusText = "未连接"
                return
            }
        }

        let msg = TunnelStartMessage(nwClientPath: exe, argv: argv)
        let payload: Data
        do {
            payload = try JSONEncoder().encode(msg)
        } catch {
            lastError = error.localizedDescription
            statusText = "未连接"
            return
        }

        statusText = "正在连接…"

        guard let proxy = remoteProxy() else {
            lastError = "无法建立 XPC"
            statusText = "未连接"
            return
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proxy.start(jsonPayload: payload as NSData) { ok, errMsg in
                Task { @MainActor in
                    if ok {
                        self.lastError = nil
                    } else {
                        self.isConnected = false
                        self.statusText = "未连接"
                        self.lastError = errMsg ?? "启动失败"
                        if let authPath {
                            try? FileManager.default.removeItem(atPath: authPath)
                        }
                    }
                    cont.resume()
                }
            }
        }

        // 进程可能因 TLS/认证/TUN 立即退出；短暂等待后再读助手状态，避免误显示「已连接」。
        try? await Task.sleep(nanoseconds: 600_000_000)
        await verifyNwClientRunningAfterStart()
    }

    /// 向 Helper 查询子进程是否仍在运行；若已退出则展示 stderr 摘要。
    private func verifyNwClientRunningAfterStart() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            remoteProxy()?.status { running, errStr in
                Task { @MainActor in
                    self.isConnected = running
                    if running {
                        self.statusText = "已连接"
                    } else {
                        self.statusText = "未连接"
                        if errStr.isEmpty {
                            self.lastError = "nw-client 已退出。请检查 CA 是否与服务器匹配、账号密码及服务端 NAT；并确认已勾选「全流量」。"
                        } else {
                            self.lastError = errStr
                        }
                    }
                    cont.resume()
                }
            }
        }
    }

    /// 应用包内 `Resources/*.txt`（由 Xcode 构建脚本从 `configs/` 复制）。
    private static func bundledRoutesPath(name: String, ext: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
        let p = url.path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    func disconnect() async {
        guard let proxy = remoteProxy() else {
            isConnected = false
            statusText = "未连接"
            xpc?.invalidate()
            xpc = nil
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proxy.stop { _, _ in
                Task { @MainActor in
                    self.isConnected = false
                    self.statusText = "未连接"
                    self.xpc?.invalidate()
                    self.xpc = nil
                    cont.resume()
                }
            }
        }
    }

}
