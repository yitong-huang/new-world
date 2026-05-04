import Foundation

/// 单条接入节点（来自 App 包内 `Resources/servers`，由构建脚本从 `configs/servers` 复制）。
/// 配置第二列只需 **主机名或 IP**（不要写端口）；连接时统一使用 `host:8443` 传给 `-server`。
struct VPNServerEntry: Identifiable, Equatable, Hashable {
    /// 与 `host` 一致，便于持久化选中项。
    var id: String { host }

    let displayName: String
    let host: String

    private static let defaultListenPort = 8443

    /// `-server`：`主机:端口`
    var serverAddress: String { "\(host):\(Self.defaultListenPort)" }
}

enum VPNServerCatalog {
    /// 包内无 `servers` 或解析为空时的兜底（与历史单节点行为一致）。
    private static let fallbackEntries: [VPNServerEntry] = [
        VPNServerEntry(displayName: "韩国", host: "new-world-kr-01.2fish.com.cn"),
    ]

    /// 配置文件里去掉空白、`\r`、UTF-8 BOM 后的一列。
    static func normalizeConfigToken(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "\r", with: "")
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s
    }

    /// 与 `UserDefaults` 里保存的选中 host 比对用：去掉误存的 `:port`，避免与列表对不上导致 `-server` 为空或错。
    static func normalizeHostLookup(_ raw: String) -> String {
        let t = normalizeConfigToken(raw)
        guard let r = t.range(of: ":", options: .literal) else { return t }
        let hostPart = String(t[..<r.lowerBound])
        let portPart = String(t[r.upperBound...])
        if !hostPart.contains(":"), !hostPart.contains("["),
           Int(portPart) != nil
        {
            return hostPart
        }
        return t
    }

    static func loadEntries() -> [VPNServerEntry] {
        guard let url = Bundle.main.url(forResource: "servers", withExtension: nil),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            return fallbackEntries
        }

        var out: [VPNServerEntry] = []
        let textNoBOM = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        for rawLine in textNoBOM.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = normalizeConfigToken(String(rawLine))
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0.isWhitespace || $0 == "\t" }).map(String.init)
            guard parts.count >= 2 else { continue }
            let displayName = normalizeConfigToken(parts[0])
            // 第二列若误写 `域名:8443`，去掉端口再存；`serverAddress` 会统一追加 `:8443`。
            let host = normalizeHostLookup(parts[1])
            if host.isEmpty { continue }
            out.append(VPNServerEntry(displayName: displayName, host: host))
        }
        return out.isEmpty ? fallbackEntries : out
    }

    static func entry(matchingSelectedHost raw: String, in entries: [VPNServerEntry]) -> VPNServerEntry? {
        let key = normalizeHostLookup(raw)
        return entries.first { normalizeHostLookup($0.host) == key }
    }

    /// 连接前务必调用：始终按当前包内列表 + 规范化后的选中 host 得到 `host:8443`。
    static func resolveServerAddress(selectedHost raw: String) -> String {
        let entries = loadEntries()
        if let e = entry(matchingSelectedHost: raw, in: entries) {
            return e.serverAddress
        }
        return entries.first?.serverAddress ?? ""
    }
}
