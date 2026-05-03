import Foundation

/// XPC 载荷：启动 `nw-client` 的 argv（不含可执行文件路径），以及可执行文件绝对路径。
struct TunnelStartMessage: Codable {
    var nwClientPath: String
    var argv: [String]
}

@objc(TunnelHelperProtocol)
protocol TunnelHelperProtocol {
    /// 使用 `NSData` 以便 XPC 与 `NSXPCInterface` 默认识别，避免额外 `setClasses`。
    func start(jsonPayload: NSData, reply: @escaping (Bool, String?) -> Void)
    func stop(reply: @escaping (Bool, String?) -> Void)
    func status(reply: @escaping (Bool, String) -> Void)
}
