import Foundation

/// 单条接入节点（来自 App 包内 `servers`，构建时从仓库 `configs/servers` 复制）。
/// 配置第二列只需主机名；连接时统一 `host:8443`。
struct VPNServerEntry: Identifiable, Equatable, Hashable {
    var id: String { host }

    let displayName: String
    let host: String

    private static let defaultListenPort = 8443

    var serverAddress: String { "\(host):\(Self.defaultListenPort)" }
}

enum VPNServerCatalog {
    private static let fallbackEntries: [VPNServerEntry] = [
        VPNServerEntry(displayName: "韩国", host: "new-world-kr-01.2fish.com.cn"),
    ]

    static func normalizeConfigToken(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "\r", with: "")
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s
    }

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

    static func resolveServerAddress(selectedHost raw: String) -> String {
        let entries = loadEntries()
        if let e = entry(matchingSelectedHost: raw, in: entries) {
            return e.serverAddress
        }
        return entries.first?.serverAddress ?? ""
    }
}
