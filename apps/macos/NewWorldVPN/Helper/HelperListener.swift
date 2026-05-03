import Foundation

final class HelperListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: TunnelHelperProtocol.self)
        newConnection.exportedObject = TunnelHelperImpl.shared
        newConnection.resume()
        return true
    }
}

final class TunnelHelperImpl: NSObject, TunnelHelperProtocol {
    static let shared = TunnelHelperImpl()

    private let lock = NSLock()
    private var vpnProcess: Process?
    private var lastError: String = ""

    func start(jsonPayload: NSData, reply: @escaping (Bool, String?) -> Void) {
        let data = jsonPayload as Data
        let dec = JSONDecoder()
        guard let msg = try? dec.decode(TunnelStartMessage.self, from: data) else {
            reply(false, "无法解析启动参数")
            return
        }

        let exe = msg.nwClientPath
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            reply(false, "nw-client 不可执行或不存在: \(exe)")
            return
        }

        lock.lock()
        defer { lock.unlock() }

        if vpnProcess?.isRunning == true {
            reply(false, "已有隧道进程在运行")
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = msg.argv
        p.environment = ProcessInfo.processInfo.environment

        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe

        do {
            try p.run()
            vpnProcess = p
            lastError = ""

            p.terminationHandler = { [weak self] proc in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                if self.vpnProcess === proc {
                    self.vpnProcess = nil
                    if proc.terminationStatus != 0 {
                        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        if let s = String(data: errData, encoding: .utf8), !s.isEmpty {
                            self.lastError = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
            }

            reply(true, nil)
        } catch {
            vpnProcess = nil
            reply(false, error.localizedDescription)
        }
    }

    func stop(reply: @escaping (Bool, String?) -> Void) {
        lock.lock()
        let proc = vpnProcess
        lock.unlock()

        guard let proc else {
            reply(true, nil)
            return
        }
        proc.terminate()
        proc.waitUntilExit()
        lock.lock()
        vpnProcess = nil
        lock.unlock()
        reply(true, nil)
    }

    func status(reply: @escaping (Bool, String) -> Void) {
        lock.lock()
        let running = vpnProcess?.isRunning == true
        let err = lastError
        lock.unlock()
        reply(running, err)
    }
}
