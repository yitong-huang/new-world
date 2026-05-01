// 与 apple/Sources/NWTunnel/PacketTunnelProvider.swift 逻辑一致；扩展目标内与 Framing.swift 同模块，故无 import NwVpnWire。
import Darwin
import Foundation
import Network
import NetworkExtension
import Security

open class PacketTunnelProvider: NEPacketTunnelProvider {
    private var connection: NWConnection?
    private var rxBuffer = Data()
    private let startTunnelCompletionLock = NSLock()
    private var didReportStartTunnelCompletion = false

    open override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let addr = proto.serverAddress
        else {
            completionHandler(NSError(domain: "NWTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing serverAddress"]))
            return
        }
        let parts = addr.split(separator: ":")
        let host = String(parts[0])
        let port: UInt16 = parts.count > 1 ? UInt16(parts[1])! : 8443

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, completion in
                completion(true) // dev only
            },
            DispatchQueue.global(),
        )

        let tcp = NWProtocolTCP.Options()
        let params = NWParameters(tls: tls, tcp: tcp)
        let nwPort = NWEndpoint.Port(integerLiteral: port)
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Task { await self.handshakeAndRun(options: options, completionHandler: completionHandler) }
            case .failed(let err):
                completionHandler(err)
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    open override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        connection?.cancel()
        connection = nil
        completionHandler()
    }

    /// 认证优先来自 `startVPNTunnel(options:)`（不落盘）；否则读 `providerConfiguration`。
    private static func tunnelAuthCredentials(
        options: [String: NSObject]?,
        tunnelProto: NETunnelProviderProtocol?,
    ) -> (user: String, pass: String) {
        func stringFromPlistValue(_ obj: Any?) -> String {
            switch obj {
            case let s as String:
                return s
            case let s as NSString:
                return s as String
            default:
                return ""
            }
        }
        func stringKeyNSObject(_ dict: [String: NSObject]?, _ key: String) -> String {
            stringFromPlistValue(dict?[key])
        }
        let ou = stringKeyNSObject(options, "username")
        let op = stringKeyNSObject(options, "password")
        if !ou.isEmpty {
            return (ou, op)
        }
        let cfg = tunnelProto?.providerConfiguration
        return (
            stringFromPlistValue(cfg?["username"]),
            stringFromPlistValue(cfg?["password"]),
        )
    }

    private func handshakeAndRun(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) async {
        guard let conn = connection else {
            completionHandler(NSError(domain: "NWTunnel", code: 2, userInfo: nil))
            return
        }
        do {
            let tunnelProto = self.protocolConfiguration as? NETunnelProviderProtocol
            let (authUser, authPass) = Self.tunnelAuthCredentials(options: options, tunnelProto: tunnelProto)
            var caps: UInt32 = 0
            if !authUser.isEmpty {
                caps |= NwCapAuthNext
            }
            let ch = NwFraming.encodeClientHello(mtu: 1400, caps: caps)
            try await sendAll(conn, NwFraming.encodeFrame(type: .clientHello, payload: ch))
            if !authUser.isEmpty {
                let ap = try NwFraming.encodeAuthCredentials(user: authUser, pass: authPass)
                try await sendAll(conn, NwFraming.encodeFrame(type: .authCredentials, payload: ap))
            }

            let sh = try await readFrame(conn)
            if sh.type == .error {
                let (c, m) = try NwFraming.decodeError(sh.payload)
                throw NSError(domain: "NWTunnel", code: Int(c), userInfo: [NSLocalizedDescriptionKey: m])
            }
            guard sh.type == .serverHello else { throw NSError(domain: "NWTunnel", code: 3, userInfo: nil) }
            let asg = try await readFrame(conn)
            guard asg.type == .assignTunnel else { throw NSError(domain: "NWTunnel", code: 4, userInfo: nil) }
            let tun = try NwFraming.decodeAssignTunnel(asg.payload)

            let ipv4 = NEIPv4Settings(addresses: [Self.ipv4String(tun.ipv4)], subnetMasks: ["255.255.255.255"])
            ipv4.includedRoutes = [NEIPv4Route.default()]
            var dns: [String] = []
            for d in tun.dns { dns.append(Self.ipv4String(d)) }
            let dnsSettings = NEDNSSettings(servers: dns.isEmpty ? ["8.8.8.8"] : dns)

            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.77.0.1")
            settings.ipv4Settings = ipv4
            settings.dnsSettings = dnsSettings
            settings.mtu = NSNumber(value: 1400)

            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                setTunnelNetworkSettings(settings) { err in
                    if let err {
                        cont.resume(throwing: err)
                        return
                    }
                    let finish: () -> Void = { [weak self] in
                        guard let self else { return }
                        self.startTunnelCompletionLock.lock()
                        defer { self.startTunnelCompletionLock.unlock() }
                        guard !self.didReportStartTunnelCompletion else { return }
                        self.didReportStartTunnelCompletion = true
                        completionHandler(nil)
                        Task {
                            do {
                                try await self.runRelay(conn: conn)
                            } catch {
                                DispatchQueue.main.async {
                                    self.cancelTunnelWithError(error)
                                }
                            }
                        }
                    }
                    if Thread.isMainThread {
                        finish()
                    } else {
                        DispatchQueue.main.async(execute: finish)
                    }
                    cont.resume()
                }
            }
        } catch {
            completionHandler(error)
        }
    }

    private func runRelay(conn: NWConnection) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.upLoop(conn: conn) }
            group.addTask { try await self.downLoop(conn: conn) }
            try await group.next()
            group.cancelAll()
        }
    }

    private func upLoop(conn: NWConnection) async throws {
        while true {
            let packets = try await readPacketsFlow()
            for p in packets {
                try await sendAll(conn, NwFraming.encodeFrame(type: .data, payload: p))
            }
        }
    }

    private func downLoop(conn: NWConnection) async throws {
        while true {
            let fr = try await readFrame(conn)
            switch fr.type {
            case .data:
                try packetFlow.writePackets([fr.payload], withProtocols: [NSNumber(value: AF_INET)])
            case .keepalive:
                try await sendAll(conn, NwFraming.encodeFrame(type: .keepalive, payload: Data()))
            default:
                break
            }
        }
    }

    private func readPacketsFlow() async throws -> [Data] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[Data], Error>) in
            packetFlow.readPackets { packets, _ in
                cont.resume(returning: packets)
            }
        }
    }

    private func sendAll(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err {
                    cont.resume(throwing: err)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func readFrame(_ conn: NWConnection) async throws -> NwFrame {
        while true {
            if let f = try popFrame(&rxBuffer) { return f }
            let chunk = try await recvSome(conn)
            rxBuffer.append(chunk)
        }
    }

    private func recvSome(_ conn: NWConnection) async throws -> Data {
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, err in
                if let err {
                    cont.resume(throwing: err)
                    return
                }
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                    return
                }
                if isComplete {
                    cont.resume(throwing: NSError(domain: "NWTunnel", code: 5, userInfo: nil))
                    return
                }
            }
        }
    }

    private func popFrame(_ buffer: inout Data) throws -> NwFrame? {
        if buffer.count < NwFraming.headerSize { return nil }
        let (_, ln) = try NwFraming.decodeHeader(buffer.prefix(NwFraming.headerSize))
        if buffer.count < NwFraming.headerSize + ln { return nil }
        let total = NwFraming.headerSize + ln
        let frameBytes = buffer.prefix(total)
        buffer.removeFirst(total)
        return try NwFraming.decodeFrame(Data(frameBytes))
    }

    private static func ipv4String(_ d: Data) -> String {
        precondition(d.count == 4)
        return "\(d[0]).\(d[1]).\(d[2]).\(d[3])"
    }
}
