import SwiftUI

/// 以 **root** 启动本程序时才能创建 TUN（与命令行 `sudo ./nw-client` 相同）。
/// 用法：`cd simple-connect && sudo swift run`
struct ContentView: View {
    @State private var connected = false
    @State private var statusText = "未连接"
    @State private var clientPath = ProcessInfo.processInfo.environment["NW_CLIENT"] ?? ""
    @State private var serverAddr = "new-world-kr-01.2fish.com.cn:8443"
    @State private var caCertPath = ""
    @State private var useSplitDefault = false
    /// 与 `-split-default` 配合：国内 IPv4 CIDR 经物理网关直连（需路由表文件）。
    @State private var useChinaDirect = false
    @State private var chinaRoutesPath = ""
    @State private var extraDirectRoutesPath = ""
    @State private var vpnProcess: Process?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NW VPN 简易面板")
                .font(.title2)

            GroupBox("路径（可改）") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("nw-client") {
                        TextField("/绝对路径/go/nw-client", text: $clientPath)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("server.crt") {
                        TextField("/绝对路径/certs/server.crt", text: $caCertPath)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            LabeledContent("服务器") {
                TextField("host:port", text: $serverAddr)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("全流量（分裂默认路由 0.0.0.0/1 + 128.0.0.0/1）", isOn: $useSplitDefault)
            Toggle("国内 IP 直连（仅墙外走隧道；需 china 路由表）", isOn: $useChinaDirect)
            if useChinaDirect {
                LabeledContent("china 路由表") {
                    TextField("configs/china_ipv4.txt", text: $chinaRoutesPath)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("补丁路由表（可选）") {
                    TextField("configs/extra_direct_ipv4.txt", text: $extraDirectRoutesPath)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button(connected ? "断开" : "连接") {
                    if connected {
                        disconnect()
                    } else {
                        connect()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)

                Text(statusText)
                    .foregroundStyle(connected ? .green : .secondary)
            }

            Text("说明：本机需 **sudo swift run** 启动；全流量还要求服务端已做 NAT。国内直连需 `configs/china_ipv4.txt` 等完整 CIDR 表（可用仓库内 `scripts/fetch-china-routes.sh` 更新）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            if clientPath.isEmpty {
                clientPath = defaultNwClientPath()
            }
            if caCertPath.isEmpty {
                caCertPath = defaultCaPath()
            }
            if chinaRoutesPath.isEmpty {
                chinaRoutesPath = defaultChinaRoutesPath()
            }
            if extraDirectRoutesPath.isEmpty {
                extraDirectRoutesPath = defaultExtraDirectRoutesPath()
            }
        }
    }

    private func defaultNwClientPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let p = env["NW_CLIENT"], !p.isEmpty { return p }
        // 从 simple-connect 目录推断仓库里的 go/nw-client
        let cwd = FileManager.default.currentDirectoryPath
        let candidate = (cwd as NSString).appendingPathComponent("../go/nw-client")
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return (candidate as NSString).standardizingPath
        }
        return ""
    }

    private func defaultCaPath() -> String {
        let cwd = FileManager.default.currentDirectoryPath
        let candidate = (cwd as NSString).appendingPathComponent("../certs/server.crt")
        if FileManager.default.fileExists(atPath: candidate) {
            return (candidate as NSString).standardizingPath
        }
        return ""
    }

    private func defaultChinaRoutesPath() -> String {
        let cwd = FileManager.default.currentDirectoryPath
        let candidate = (cwd as NSString).appendingPathComponent("../configs/china_ipv4.txt")
        if FileManager.default.fileExists(atPath: candidate) {
            return (candidate as NSString).standardizingPath
        }
        return ""
    }

    private func defaultExtraDirectRoutesPath() -> String {
        let cwd = FileManager.default.currentDirectoryPath
        let candidate = (cwd as NSString).appendingPathComponent("../configs/extra_direct_ipv4.txt")
        if FileManager.default.fileExists(atPath: candidate) {
            return (candidate as NSString).standardizingPath
        }
        return ""
    }

    private func connect() {
        let exe = (clientPath as NSString).standardizingPath
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            statusText = "找不到可执行的 nw-client"
            return
        }
        guard getuid() == 0 else {
            statusText = "需要 root：请在终端执行 sudo swift run"
            return
        }
        let ca = (caCertPath as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: ca) else {
            statusText = "找不到 server.crt"
            return
        }

        if useChinaDirect {
            let cr = (chinaRoutesPath as NSString).standardizingPath
            guard !cr.isEmpty, FileManager.default.fileExists(atPath: cr) else {
                statusText = "国内直连需填写存在的 china 路由表路径"
                return
            }
            let er = (extraDirectRoutesPath as NSString).standardizingPath
            if !er.isEmpty, !FileManager.default.fileExists(atPath: er) {
                statusText = "补丁路由表路径不存在"
                return
            }
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        var args = ["-server", serverAddr, "-cacert", ca]
        let splitOn = useSplitDefault || useChinaDirect
        if splitOn {
            args.append("-split-default")
        }
        if useChinaDirect {
            let cr = (chinaRoutesPath as NSString).standardizingPath
            args.append(contentsOf: ["-china-routes", cr])
            let er = (extraDirectRoutesPath as NSString).standardizingPath
            if !er.isEmpty {
                args.append(contentsOf: ["-extra-direct-routes", er])
            }
        }
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
            vpnProcess = p
            connected = true
            statusText = "已连接"
        } catch {
            statusText = "启动失败: \(error.localizedDescription)"
        }
    }

    private func disconnect() {
        vpnProcess?.terminate()
        vpnProcess?.waitUntilExit()
        vpnProcess = nil
        connected = false
        statusText = "已断开"
    }
}
