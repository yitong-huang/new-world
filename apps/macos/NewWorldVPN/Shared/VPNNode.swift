import Foundation

/// 接入节点；扩展时增加 `case` 并填写 `title` / `serverAddress`。
enum VPNNode: String, CaseIterable, Identifiable {
    case korea

    var id: String { rawValue }

    var title: String {
        switch self {
        case .korea: return "韩国"
        }
    }

    /// `-server`：`主机:端口`
    var serverAddress: String {
        switch self {
        case .korea: return "new-world-kr-01.2fish.com.cn:8443"
        }
    }
}
