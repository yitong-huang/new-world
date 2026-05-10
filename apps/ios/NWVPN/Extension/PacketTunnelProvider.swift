import Darwin
import Foundation
import Network
import NetworkExtension
import OSLog
import Security

open class PacketTunnelProvider: NEPacketTunnelProvider {
    /// iOS 对 `excludedRoutes` 体量很敏感；过大时 `setTunnelNetworkSettings` 易失败并表现为 “internal error”。
    /// 实测 512 仍偶发失败，收紧到 128；若仍失败会再尝试仅排除 VPN 服务器（见 `handshakeAndRun`）。
    private static let maxExcludedRoutes = 128
    private let logger = Logger(subsystem: "com.newworld.nwvpn.ios", category: "PacketTunnel")
    /// 与 `NWConnection.start(queue:)` 一致；send/receive 的 completion 也在此队列上触发。
    private let nwQueue = DispatchQueue(label: "com.newworld.NWVPNiOS.PacketTunnel.nw")
    /// `readPackets` 空数组时不要用主队列自旋递归，避免挤压 UI 队列。
    private let packetPollQueue = DispatchQueue(label: "com.newworld.NWVPNiOS.PacketTunnel.packetPoll", qos: .utility)
    private var connection: NWConnection?
    private var rxBuffer = Data()

    /// 递增世代：短时多次 `startTunnel` / 多条 `NWConnection.ready` 时，只允许**当前这一代**握手，避免并行 `receive`/`rxBuffer` 互踩（症状：rxRemain 已有整帧却一直等 AssignTunnel）。
    private let wireGenLock = NSLock()
    private var wireGeneration: UInt64 = 0

    /// **`stateUpdateHandler` 未必与 `NWConnection.start(queue:)` 同队列**；把「只允许一次握手」与 `NWConnection.receive` 的约定全部收敛到 `nwQueue`。
    private var nwHandshakeBegunGeneration: UInt64 = 0
    private var handshakeBootstrapTask: Task<Void, Never>?

    /// 任意时刻最多 **一幅** TLS 读出回调，多个 `receive`/`recvSome` waiter 在同一 `nwQueue` 上 FIFO 认领字节块；否则会永久卡在等 AssignTunnel。
    private var nwRecvInFlight = false
    private var nwRecvTickets: [CheckedContinuation<Data, Error>] = []
    private var nwRecvPrefetchedChunks: [Data] = []
    /// 与 `NWConnection.receive` 的 completion 对齐；重连/`stopTunnel` 时递增，丢弃过期回调以免误配对 waiter。
    private var nwRecvEpoch: UInt64 = 0
    private var memorySampleTask: Task<Void, Never>?

    private let relayStatsLock = NSLock()
    private var relayUpPackets: UInt64 = 0
    private var relayDownPackets: UInt64 = 0
    private var relayUpBytes: UInt64 = 0
    private var relayDownBytes: UInt64 = 0
    private var relayMaxRxBufferBytes: Int = 0
    private var relaySelfTunnelPackets: UInt64 = 0
    private var relaySelfTunnelBytes: UInt64 = 0
    private var serverIPv4ForLoopCheck: String?
    private var serverPortForLoopCheck: UInt16 = 0

    private let startTunnelCompletionLock = NSLock()
    private var didReportStartTunnelCompletion = false

    private func bumpWireGeneration() -> UInt64 {
        wireGenLock.lock()
        defer { wireGenLock.unlock() }
        wireGeneration &+= 1
        return wireGeneration
    }

    private func currentWireGeneration() -> UInt64 {
        wireGenLock.lock()
        defer { wireGenLock.unlock() }
        return wireGeneration
    }

    open override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let addr = proto.serverAddress
        else {
            logger.error("startTunnel failed: missing serverAddress")
            // #region agent log
            AgentDebugLog.log(hypothesisId: "H3", location: "PacketTunnelProvider.startTunnel", message: "missing_serverAddress", data: [:])
            // #endregion
            invokeStartTunnelCompletionOnMain(handler: completionHandler, error: NSError(domain: "NWTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing serverAddress"]))
            return
        }
        let parts = addr.split(separator: ":")
        let host = String(parts[0])
        let port: UInt16 = parts.count > 1 ? UInt16(parts[1]) ?? 8443 : 8443
        serverPortForLoopCheck = port

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, completion in
                completion(true) // dev only
            },
            DispatchQueue.global()
        )

        let tcp = NWProtocolTCP.Options()
        let params = NWParameters(tls: tls, tcp: tcp)
        let nwPort = NWEndpoint.Port(integerLiteral: port)
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)

        let tunnelGen = bumpWireGeneration()
        // #region agent log
        AgentDebugLog.log(
            hypothesisId: "H3",
            location: "PacketTunnelProvider.startTunnel",
            message: "begin",
            data: [
                "host": host,
                "port": String(port),
                "wireGen": String(tunnelGen),
                "serverAddress": addr,
            ],
        )
        // #endregion

        connection?.cancel()
        connection = nil
        rxBuffer.removeAll(keepingCapacity: false)

        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        nwQueue.sync { [weak self] in
            guard let self else { return }
            self.nwRecvEpoch &+= 1
            self.nwHandshakeBegunGeneration = 0
            self.handshakeBootstrapTask?.cancel()
            self.handshakeBootstrapTask = nil
            self.memorySampleTask?.cancel()
            self.memorySampleTask = nil
            self.nwRecvCancelAll(reason: NSError(domain: "NWTunnel", code: 6, userInfo: [NSLocalizedDescriptionKey: "tunnel restarted"]))
        }

        startTunnelCompletionLock.lock()
        didReportStartTunnelCompletion = false
        startTunnelCompletionLock.unlock()
        startMemorySampling()

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.nwQueue.async { [weak self] in
                    guard let self else { return }
                    guard self.currentWireGeneration() == tunnelGen else {
                        return
                    }
                    if self.nwHandshakeBegunGeneration == tunnelGen {
                        return
                    }
                    self.nwHandshakeBegunGeneration = tunnelGen
                    self.handshakeBootstrapTask?.cancel()
                    self.logger.info("NWConnection ready, start handshake")
                    // #region agent log
                    AgentDebugLog.log(
                        hypothesisId: "H2",
                        location: "PacketTunnelProvider.NWConnection.state",
                        message: "ready",
                        data: ["wireGen": String(tunnelGen)],
                    )
                    // #endregion
                    self.handshakeBootstrapTask = Task {
                        await self.handshakeAndRun(wireGen: tunnelGen, completionHandler: completionHandler)
                    }
                }
            case .failed(let err):
                guard self.currentWireGeneration() == tunnelGen else {
                    return
                }
                self.logger.error("NWConnection failed: \(err.localizedDescription, privacy: .public)")
                // #region agent log
                AgentDebugLog.log(
                    hypothesisId: "H2",
                    location: "PacketTunnelProvider.NWConnection.state",
                    message: "failed",
                    data: [
                        "desc": err.localizedDescription,
                        "wireGen": String(tunnelGen),
                    ],
                )
                // #endregion
                self.startTunnelCompletionLock.lock()
                let already = self.didReportStartTunnelCompletion
                self.startTunnelCompletionLock.unlock()
                if already {
                    self.cancelTunnelWithError(err)
                } else {
                    self.invokeStartTunnelCompletionOnMain(handler: completionHandler, error: err)
                }
            case .waiting(let err):
                guard self.currentWireGeneration() == tunnelGen else { return }
                self.logger.error("NWConnection waiting: \(err.localizedDescription, privacy: .public)")
                // #region agent log
                AgentDebugLog.log(
                    hypothesisId: "H2",
                    location: "PacketTunnelProvider.NWConnection.state",
                    message: "waiting",
                    data: [
                        "desc": err.localizedDescription,
                        "wireGen": String(tunnelGen),
                    ],
                )
                // #endregion
            default:
                break
            }
        }
        logger.info("startTunnel connecting to \(host, privacy: .public):\(port)")
        conn.start(queue: nwQueue)
    }

    /// 必须在「主队列」上对 `completionHandler` 至多调用一次；可从任意队列调用本方法。
    private func invokeStartTunnelCompletionOnMain(handler: @escaping (Error?) -> Void, error: Error?) {
        let work = { [self] in
            self.startTunnelCompletionLock.lock()
            defer { self.startTunnelCompletionLock.unlock() }
            guard !self.didReportStartTunnelCompletion else { return }
            self.didReportStartTunnelCompletion = true
            // #region agent log
            let n = error as NSError?
            AgentDebugLog.log(
                hypothesisId: "H3",
                location: "PacketTunnelProvider.invokeStartTunnelCompletionOnMain",
                message: error == nil ? "completion_ok" : "completion_error",
                data: [
                    "desc": error?.localizedDescription ?? "",
                    "domain": n?.domain ?? "",
                    "code": n.map { String($0.code) } ?? "",
                ],
            )
            // #endregion
            handler(error)
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    open override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        // #region agent log
        AgentDebugLog.log(
            hypothesisId: "H4",
            location: "PacketTunnelProvider.stopTunnel",
            message: "called",
            data: ["reason": String(reason.rawValue)],
        )
        // #endregion
        _ = bumpWireGeneration()
        nwQueue.sync { [weak self] in
            guard let self else { return }
            self.nwRecvEpoch &+= 1
            self.handshakeBootstrapTask?.cancel()
            self.handshakeBootstrapTask = nil
            self.memorySampleTask?.cancel()
            self.memorySampleTask = nil
            self.nwHandshakeBegunGeneration = 0
            self.nwRecvCancelAll(reason: NSError(domain: "NWTunnel", code: 7, userInfo: [NSLocalizedDescriptionKey: "tunnel stopped"]))
        }
        connection?.cancel()
        connection = nil
        rxBuffer.removeAll(keepingCapacity: false)
        completionHandler()
    }

    /// 仅由 `nwQueue` 调用；取消在等待中的 `receive` waiter（例如重连、`stopTunnel`）。
    private func nwRecvCancelAll(reason: Error) {
        nwRecvPrefetchedChunks.removeAll()
        nwRecvInFlight = false
        let waiters = nwRecvTickets
        nwRecvTickets.removeAll()
        for w in waiters {
            w.resume(throwing: reason)
        }
    }

    /// 仅由 `nwQueue` 调用：把 prefetch 分给排队中的 waiter；若仍有 waiter 且无在途 `receive` 则再挂一幅。
    private func nwRecvServeOrArmReceive(_ conn: NWConnection) {
        while !nwRecvTickets.isEmpty, !nwRecvPrefetchedChunks.isEmpty {
            let chunk = nwRecvPrefetchedChunks.removeFirst()
            let waiter = nwRecvTickets.removeFirst()
            waiter.resume(returning: chunk)
        }
        guard !nwRecvTickets.isEmpty else { return }
        guard !nwRecvInFlight else { return }
        nwRecvInFlight = true
        let armEpoch = nwRecvEpoch
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, nwErr in
            guard let self else { return }
            self.nwQueue.async {
                self.nwRecvHandleReceiveCompletion(
                    conn,
                    expectedArmEpoch: armEpoch,
                    content: data,
                    isComplete: isComplete,
                    nwErr: nwErr,
                )
            }
        }
    }

    /// 仅由 `nwQueue` 调用：`receive` 回调落回串行上下文。
    private func nwRecvHandleReceiveCompletion(
        _ conn: NWConnection,
        expectedArmEpoch: UInt64,
        content: Data?,
        isComplete: Bool,
        nwErr: NWError?,
    ) {
        guard expectedArmEpoch == nwRecvEpoch else {
            return
        }
        nwRecvInFlight = false
        if let nwErr {
            // #region agent log
            AgentDebugLog.log(
                hypothesisId: "H4",
                location: "PacketTunnelProvider.nwRecvHandleReceiveCompletion",
                message: "receive_error",
                data: [
                    "desc": nwErr.localizedDescription,
                    "epoch": String(nwRecvEpoch),
                    "tickets": String(nwRecvTickets.count),
                ],
            )
            // #endregion
            nwRecvCancelAll(reason: nwErr)
            return
        }
        if let content, !content.isEmpty {
            if nwRecvTickets.isEmpty {
                nwRecvPrefetchedChunks.append(content)
            } else {
                let waiter = nwRecvTickets.removeFirst()
                waiter.resume(returning: content)
            }
            nwRecvServeOrArmReceive(conn)
            return
        }
        if isComplete {
            // #region agent log
            AgentDebugLog.log(
                hypothesisId: "H4",
                location: "PacketTunnelProvider.nwRecvHandleReceiveCompletion",
                message: "receive_complete",
                data: [
                    "epoch": String(nwRecvEpoch),
                    "tickets": String(nwRecvTickets.count),
                    "contentBytes": String(content?.count ?? 0),
                ],
            )
            // #endregion
            nwRecvCancelAll(
                reason: NSError(domain: "NWTunnel", code: 5, userInfo: [NSLocalizedDescriptionKey: "TLS closed before frame"]),
            )
            return
        }
        nwRecvServeOrArmReceive(conn)
    }

    /// 若已过时的 `startTunnel`/stop 抢占了世代，`completionHandler` 只报告一次 superseded。
    private func handshakeSuperseded(wireGen: UInt64, completionHandler: @escaping (Error?) -> Void) -> Bool {
        guard currentWireGeneration() != wireGen else { return false }
        invokeStartTunnelCompletionOnMain(
            handler: completionHandler,
            error: NSError(
                domain: "NWTunnel",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "tunnel handshake superseded"],
            ),
        )
        return true
    }

    private func handshakeAndRun(wireGen: UInt64, completionHandler: @escaping (Error?) -> Void) async {
        guard !handshakeSuperseded(wireGen: wireGen, completionHandler: completionHandler) else { return }
        guard let conn = connection else {
            invokeStartTunnelCompletionOnMain(handler: completionHandler, error: NSError(domain: "NWTunnel", code: 2, userInfo: nil))
            return
        }
        do {
            let tunnelProto = self.protocolConfiguration as? NETunnelProviderProtocol
            let providerCfg = tunnelProto?.providerConfiguration
            let authUser = Self.cfgString(providerCfg?["username"])
            let authPass = Self.cfgString(providerCfg?["password"])
            let chinaDirectEnabled = (providerCfg?["china_direct_enabled"] as? NSNumber)?.boolValue ?? false
            try Task.checkCancellation()
            logger.info("handshake begin, chinaDirect=\(chinaDirectEnabled)")

            var caps: UInt32 = 0
            if !authUser.isEmpty {
                caps |= NwCapAuthNext
            }
            let ch = NwFraming.encodeClientHello(mtu: 1400, caps: caps)
            try Task.checkCancellation()
            try await sendAll(conn, NwFraming.encodeFrame(type: .clientHello, payload: ch))
            if handshakeSuperseded(wireGen: wireGen, completionHandler: completionHandler) { return }
            if !authUser.isEmpty {
                let ap = try NwFraming.encodeAuthCredentials(user: authUser, pass: authPass)
                try await sendAll(conn, NwFraming.encodeFrame(type: .authCredentials, payload: ap))
                if handshakeSuperseded(wireGen: wireGen, completionHandler: completionHandler) { return }
            }

            let sh = try await readFrame(conn)
            if handshakeSuperseded(wireGen: wireGen, completionHandler: completionHandler) { return }
            if sh.type == .error {
                let (c, m) = try NwFraming.decodeError(sh.payload)
                throw NSError(domain: "NWTunnel", code: Int(c), userInfo: [NSLocalizedDescriptionKey: m])
            }
            guard sh.type == .serverHello else { throw NSError(domain: "NWTunnel", code: 3, userInfo: nil) }

            try Task.checkCancellation()
            let asg = try await readFrame(conn)
            if handshakeSuperseded(wireGen: wireGen, completionHandler: completionHandler) { return }
            guard asg.type == .assignTunnel else { throw NSError(domain: "NWTunnel", code: 4, userInfo: nil) }
            let tun = try NwFraming.decodeAssignTunnel(asg.payload)
            if handshakeSuperseded(wireGen: wireGen, completionHandler: completionHandler) { return }

            let vpnServerHostname = Self.vpnServerHost(fromServerAddress: (self.protocolConfiguration as? NETunnelProviderProtocol)?.serverAddress)
            var includeChinaTables = chinaDirectEnabled
            let maxSettingsAttempts = chinaDirectEnabled ? 2 : 1
            for attempt in 0 ..< maxSettingsAttempts {
                if handshakeSuperseded(wireGen: wireGen, completionHandler: completionHandler) { return }
                let (settings, exCount) = buildTunnelNetworkSettings(
                    tun: tun,
                    conn: conn,
                    vpnServerHostname: vpnServerHostname,
                    chinaDirectEnabled: chinaDirectEnabled,
                    includeChinaBypassExcludedRoutes: includeChinaTables,
                )
                let serverIPv4 = currentServerIPv4(conn)
                serverIPv4ForLoopCheck = serverIPv4
                // #region agent log
                AgentDebugLog.log(
                    hypothesisId: "H1",
                    location: "PacketTunnelProvider.before_setTunnelNetworkSettings",
                    message: "network_settings_built",
                    data: [
                        "attempt": String(attempt),
                        "chinaDirect": String(chinaDirectEnabled),
                        "includeChinaTables": String(includeChinaTables),
                        "excludedCount": String(exCount),
                        "dnsCount": String(tun.dns.count),
                        "serverIPv4Resolved": serverIPv4 != nil ? "true" : "false",
                        "serverIPv4": serverIPv4 ?? "",
                    ],
                )
                // #endregion
                do {
                    try await setTunnelNetworkSettingsAsync(settings)
                    self.logger.info("setTunnelNetworkSettings succeeded attempt=\(attempt)")
                    if attempt > 0 {
                        self.logger.warning("国内直连路由表已降级：仅保留 VPN 服务器绕行，避免 setTunnelNetworkSettings 失败（系统 internal error）")
                    }
                    // #region agent log
                    AgentDebugLog.log(
                        hypothesisId: "H1",
                        location: "PacketTunnelProvider.setTunnelNetworkSettings",
                        message: "ok",
                        data: ["attempt": String(attempt)],
                    )
                    // #endregion
                    let finish: () -> Void = { [self] in
                        self.startTunnelCompletionLock.lock()
                        defer { self.startTunnelCompletionLock.unlock() }
                        guard !self.didReportStartTunnelCompletion else { return }
                        self.didReportStartTunnelCompletion = true
                        // #region agent log
                        AgentDebugLog.log(
                            hypothesisId: "H3",
                            location: "PacketTunnelProvider.handshakeAndRun",
                            message: "completion_ok_after_settings",
                            data: ["wireGen": String(wireGen)],
                        )
                        // #endregion
                        completionHandler(nil)
                        Task {
                            do {
                                try await self.runRelay(conn: conn)
                            } catch {
                                self.logger.error("runRelay ended: \(error.localizedDescription, privacy: .public)")
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
                    break
                } catch {
                    self.logger.error("setTunnelNetworkSettings failed attempt=\(attempt): \(error.localizedDescription, privacy: .public)")
                    // #region agent log
                    let n = error as NSError
                    AgentDebugLog.log(
                        hypothesisId: "H1",
                        location: "PacketTunnelProvider.setTunnelNetworkSettings",
                        message: "failed",
                        data: [
                            "attempt": String(attempt),
                            "desc": error.localizedDescription,
                            "domain": n.domain,
                            "code": String(n.code),
                        ],
                    )
                    // #endregion
                    if attempt == 0, chinaDirectEnabled, includeChinaTables {
                        // #region agent log
                        AgentDebugLog.log(
                            hypothesisId: "H1",
                            location: "PacketTunnelProvider.setTunnelNetworkSettings",
                            message: "retry_without_china_tables",
                            data: [:],
                        )
                        // #endregion
                        includeChinaTables = false
                        continue
                    }
                    throw error
                }
            }
        } catch is CancellationError {
            invokeStartTunnelCompletionOnMain(
                handler: completionHandler,
                error: NSError(
                    domain: "NWTunnel",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "tunnel handshake canceled"],
                ),
            )
        } catch {
            logger.error("handshakeAndRun failed: \(error.localizedDescription, privacy: .public)")
            // #region agent log
            let n = error as NSError
            AgentDebugLog.log(
                hypothesisId: "H5",
                location: "PacketTunnelProvider.handshakeAndRun",
                message: "catch",
                data: [
                    "desc": error.localizedDescription,
                    "domain": n.domain,
                    "code": String(n.code),
                ],
            )
            // #endregion
            invokeStartTunnelCompletionOnMain(handler: completionHandler, error: error)
        }
    }

    private static func cfgString(_ any: Any?) -> String {
        switch any {
        case let s as String:
            return s
        case let s as NSString:
            return s as String
        default:
            return ""
        }
    }

    private func runRelay(conn: NWConnection) async throws {
        // #region agent log
        AgentDebugLog.log(hypothesisId: "H4", location: "PacketTunnelProvider.runRelay", message: "start", data: [:])
        // #endregion
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await self.upLoop(conn: conn)
                return "upLoop"
            }
            group.addTask {
                try await self.downLoop(conn: conn)
                return "downLoop"
            }
            do {
                if let endedLoop = try await group.next() {
                    // #region agent log
                    AgentDebugLog.log(
                        hypothesisId: "H4",
                        location: "PacketTunnelProvider.runRelay",
                        message: "loop_returned",
                        data: ["loop": endedLoop],
                    )
                    // #endregion
                }
                group.cancelAll()
            } catch {
                let n = error as NSError
                // #region agent log
                AgentDebugLog.log(
                    hypothesisId: "H4",
                    location: "PacketTunnelProvider.runRelay",
                    message: "loop_threw",
                    data: [
                        "desc": error.localizedDescription,
                        "domain": n.domain,
                        "code": String(n.code),
                    ],
                )
                // #endregion
                group.cancelAll()
                throw error
            }
        }
    }

    private func upLoop(conn: NWConnection) async throws {
        while true {
            let packets = try await readPacketsFlow()
            for p in packets {
                recordRelayUp(bytes: p.count)
                recordPotentialSelfTunnelPacket(p)
                try await sendAll(conn, NwFraming.encodeFrame(type: .data, payload: p))
            }
        }
    }

    private func downLoop(conn: NWConnection) async throws {
        while true {
            let fr = try await readFrame(conn)
            switch fr.type {
            case .data:
                recordRelayDown(bytes: fr.payload.count)
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
            func read() {
                packetFlow.readPackets { packets, _ in
                    if packets.isEmpty {
                        self.packetPollQueue.asyncAfter(deadline: .now() + 0.002) {
                            read()
                        }
                    } else {
                        cont.resume(returning: packets)
                    }
                }
            }
            read()
        }
    }

    private func sendAll(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nwQueue.async {
                conn.send(content: data, completion: .contentProcessed { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                })
            }
        }
    }

    private func readFrame(_ conn: NWConnection) async throws -> NwFrame {
        while true {
            if let f = try popFrame(&rxBuffer) { return f }
            let chunk = try await recvSome(conn)
            rxBuffer.append(chunk)
            recordRxBufferSize(rxBuffer.count)
        }
    }

    private func recvSome(_ conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            nwQueue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: NSError(domain: "NWTunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: "provider deallocated"]))
                    return
                }
                self.nwRecvTickets.append(cont)
                self.nwRecvServeOrArmReceive(conn)
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

    private func setTunnelNetworkSettingsAsync(_ settings: NEPacketTunnelNetworkSettings) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(settings) { err in
                if let err {
                    cont.resume(throwing: err)
                } else {
                    cont.resume()
                }
            }
        }
    }

    private func buildTunnelNetworkSettings(
        tun: NwFraming.AssignTunnel,
        conn: NWConnection,
        vpnServerHostname: String?,
        chinaDirectEnabled: Bool,
        includeChinaBypassExcludedRoutes: Bool,
    ) -> (NEPacketTunnelNetworkSettings, Int) {
        let tunIP = Self.ipv4String(tun.ipv4)
        let ipv4 = NEIPv4Settings(addresses: [tunIP], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        var excludedRoutes: [NEIPv4Route] = []
        if chinaDirectEnabled, includeChinaBypassExcludedRoutes {
            let rs = loadDirectBypassRoutes()
            logger.info("excluded routes count=\(rs.count)")
            excludedRoutes.append(contentsOf: rs)
        }
        let fromPath = currentServerIPv4(conn)
        let fromDNS: String? = {
            guard fromPath == nil, let h = vpnServerHostname else { return nil }
            return Self.resolveHostnameToFirstIPv4(h)
        }()
        if let serverIPv4 = fromPath ?? fromDNS {
            excludedRoutes.append(NEIPv4Route(destinationAddress: serverIPv4, subnetMask: "255.255.255.255"))
            let src = fromPath != nil ? "nwPath" : "dns"
            logger.info("exclude vpn server host route=\(serverIPv4, privacy: .public) source=\(src, privacy: .public)")
        } else {
            logger.error("cannot resolve server IPv4 from currentPath or DNS, may loop after default route")
        }
        if !excludedRoutes.isEmpty {
            ipv4.excludedRoutes = excludedRoutes
        }
        var dns: [String] = []
        for d in tun.dns { dns.append(Self.ipv4String(d)) }
        let dnsSettings = NEDNSSettings(servers: dns.isEmpty ? ["8.8.8.8"] : dns)
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.77.0.1")
        settings.ipv4Settings = ipv4
        settings.dnsSettings = dnsSettings
        settings.mtu = NSNumber(value: 1400)
        return (settings, excludedRoutes.count)
    }

    private func loadDirectBypassRoutes() -> [NEIPv4Route] {
        var routes: [NEIPv4Route] = []
        var seen = Set<String>()
        // 先合并 mainland 表再补丁表；总量受 `maxExcludedRoutes` 限制（过大会触发 setTunnelNetworkSettings 失败 / internal error）。
        for name in ["china_ipv4", "extra_direct_ipv4"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
                  let content = try? String(contentsOf: url, encoding: .utf8)
            else {
                continue
            }
            for raw in content.split(separator: "\n") {
                var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if let idx = line.firstIndex(of: "#") {
                    line = String(line[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if line.isEmpty || seen.contains(line) { continue }
                if let route = Self.ipv4Route(fromCIDR: line) {
                    seen.insert(line)
                    routes.append(route)
                    if routes.count >= Self.maxExcludedRoutes {
                        return routes
                    }
                }
            }
        }
        return routes
    }

    private static func ipv4Route(fromCIDR cidr: String) -> NEIPv4Route? {
        let parts = cidr.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (1...32).contains(prefix),
              let base = ipv4UInt32(parts[0])
        else {
            return nil
        }
        let mask: UInt32 = UInt32.max << (32 - UInt32(prefix))
        let network = base & mask
        return NEIPv4Route(destinationAddress: uint32ToIPv4(network), subnetMask: uint32ToIPv4(mask))
    }

    private static func ipv4UInt32(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var out: UInt32 = 0
        for p in parts {
            guard let v = UInt8(p) else { return nil }
            out = (out << 8) | UInt32(v)
        }
        return out
    }

    private static func uint32ToIPv4(_ v: UInt32) -> String {
        let a = (v >> 24) & 0xFF
        let b = (v >> 16) & 0xFF
        let c = (v >> 8) & 0xFF
        let d = v & 0xFF
        return "\(a).\(b).\(c).\(d)"
    }

    private static func ipv4String(_ d: Data) -> String {
        precondition(d.count == 4)
        return "\(d[0]).\(d[1]).\(d[2]).\(d[3])"
    }

    private func currentServerIPv4(_ conn: NWConnection) -> String? {
        guard case let .hostPort(host, _) = conn.currentPath?.remoteEndpoint else {
            return nil
        }
        switch host {
        case let .ipv4(addr):
            // 勿用 debugDescription：可能含 scope/非点分格式，NEIPv4Route 会整段失败 → internal error。
            return Self.dottedDecimalIPv4(addr)
        default:
            return nil
        }
    }

    private static func dottedDecimalIPv4(_ addr: IPv4Address) -> String? {
        let b = [UInt8](addr.rawValue)
        guard b.count == 4 else { return nil }
        return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
    }

    /// `NETunnelProviderProtocol.serverAddress` 的主机部分（不含端口）；不支持 `[v6]:port` 形态。
    private static func vpnServerHost(fromServerAddress addr: String?) -> String? {
        guard let addr, !addr.isEmpty else { return nil }
        if addr.contains("[") { return nil }
        let parts = addr.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first else { return nil }
        let host = String(first)
        return host.isEmpty ? nil : host
    }

    /// 当 `NWConnection.currentPath.remoteEndpoint` 仍为 `.name` 等、拿不到 IPv4 时，用 A 记录补全，以便下发 VPN 服务器 `/32` excludedRoute，避免默认路由进隧道后 TLS 对端被误送进隧道。
    private static func resolveHostnameToFirstIPv4(_ hostname: String) -> String? {
        guard !hostname.isEmpty else { return nil }
        if ipv4UInt32(hostname) != nil {
            return hostname
        }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG
        var res: UnsafeMutablePointer<addrinfo>?
        defer {
            if let r = res {
                freeaddrinfo(r)
            }
        }
        guard getaddrinfo(hostname, nil, &hints, &res) == 0, let first = res else { return nil }
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let p = ptr {
            if p.pointee.ai_family == AF_INET, let sa = p.pointee.ai_addr {
                let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var addr = sin.sin_addr
                return withUnsafeBytes(of: &addr) { buf in
                    guard buf.count >= 4 else { return nil as String? }
                    let b = buf.bindMemory(to: UInt8.self)
                    return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
                }
            }
            ptr = p.pointee.ai_next
        }
        return nil
    }

    private func recordRelayUp(bytes: Int) {
        relayStatsLock.lock()
        relayUpPackets &+= 1
        relayUpBytes &+= UInt64(bytes)
        relayStatsLock.unlock()
    }

    private func recordRelayDown(bytes: Int) {
        relayStatsLock.lock()
        relayDownPackets &+= 1
        relayDownBytes &+= UInt64(bytes)
        relayStatsLock.unlock()
    }

    private func recordRxBufferSize(_ bytes: Int) {
        relayStatsLock.lock()
        if bytes > relayMaxRxBufferBytes {
            relayMaxRxBufferBytes = bytes
        }
        relayStatsLock.unlock()
    }

    private func relayStatsSnapshot() -> [String: String] {
        relayStatsLock.lock()
        defer { relayStatsLock.unlock() }
        return [
            "upPackets": String(relayUpPackets),
            "downPackets": String(relayDownPackets),
            "upBytes": String(relayUpBytes),
            "downBytes": String(relayDownBytes),
            "maxRxBufferBytes": String(relayMaxRxBufferBytes),
            "selfTunnelPackets": String(relaySelfTunnelPackets),
            "selfTunnelBytes": String(relaySelfTunnelBytes),
            "serverIPv4ForLoopCheck": serverIPv4ForLoopCheck ?? "",
            "serverPortForLoopCheck": String(serverPortForLoopCheck),
        ]
    }

    private func recordPotentialSelfTunnelPacket(_ packet: Data) {
        guard let serverIPv4ForLoopCheck,
              let serverIP = Self.ipv4UInt32(serverIPv4ForLoopCheck),
              let info = Self.ipv4TransportInfo(packet),
              info.dstIP == serverIP,
              info.dstPort == serverPortForLoopCheck
        else {
            return
        }
        relayStatsLock.lock()
        relaySelfTunnelPackets &+= 1
        relaySelfTunnelBytes &+= UInt64(packet.count)
        let shouldLog = relaySelfTunnelPackets <= 5 || relaySelfTunnelPackets.isMultiple(of: 100)
        let count = relaySelfTunnelPackets
        relayStatsLock.unlock()
        if shouldLog {
            // #region agent log
            AgentDebugLog.log(
                hypothesisId: "H9",
                location: "PacketTunnelProvider.upLoop",
                message: "self_tunnel_packet",
                data: [
                    "count": String(count),
                    "bytes": String(packet.count),
                    "dst": serverIPv4ForLoopCheck,
                    "dstPort": String(serverPortForLoopCheck),
                ],
            )
            // #endregion
        }
    }

    private static func ipv4TransportInfo(_ packet: Data) -> (dstIP: UInt32, dstPort: UInt16)? {
        let b = [UInt8](packet.prefix(40))
        guard b.count >= 20 else { return nil }
        let version = b[0] >> 4
        let ihl = Int(b[0] & 0x0F) * 4
        guard version == 4, ihl >= 20, b.count >= ihl + 4 else { return nil }
        let proto = b[9]
        guard proto == 6 || proto == 17 else { return nil }
        let dstIP = (UInt32(b[16]) << 24) | (UInt32(b[17]) << 16) | (UInt32(b[18]) << 8) | UInt32(b[19])
        let dstPort = (UInt16(b[ihl + 2]) << 8) | UInt16(b[ihl + 3])
        return (dstIP, dstPort)
    }

    private func recvStateSnapshot() -> [String: String] {
        nwQueue.sync {
            [
                "rxBufferBytes": String(rxBuffer.count),
                "tickets": String(nwRecvTickets.count),
                "prefetchChunks": String(nwRecvPrefetchedChunks.count),
                "prefetchBytes": String(nwRecvPrefetchedChunks.reduce(0) { $0 + $1.count }),
                "recvInFlight": String(nwRecvInFlight),
                "recvEpoch": String(nwRecvEpoch),
            ]
        }
    }

    private func startMemorySampling() {
        memorySampleTask?.cancel()
        memorySampleTask = Task { [weak self] in
            guard let self else { return }
            for sample in 0 ..< 60 {
                if Task.isCancelled { return }
                if sample > 0 {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                }
                if Task.isCancelled { return }
                var data = self.relayStatsSnapshot()
                data.merge(self.recvStateSnapshot()) { _, new in new }
                data["residentMB"] = String(Self.residentMemoryBytes() / 1_048_576)
                data["sample"] = String(sample)
                // #region agent log
                AgentDebugLog.log(
                    hypothesisId: "H8",
                    location: "PacketTunnelProvider.memory",
                    message: "sample",
                    data: data,
                )
                // #endregion
            }
        }
    }

    private static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }
}

// MARK: - Debug NDJSON（与 PacketTunnel 同文件，避免 Xcode 工程未纳入新 .swift 时 “Cannot find in scope”）
/// 仅写 OSLog（subsystem `com.newworld.nwvpn.ios.debug`）；真机扩展沙盒不能直接写 Mac 路径。
/// 转存到仓库日志见 `scripts/ios_device_logs_to_cursor.sh` / README。
fileprivate enum AgentDebugLog {
    private static let sessionId = "2902a2"
    private static let dbgLogger = Logger(subsystem: "com.newworld.nwvpn.ios.debug", category: "NDJSON")

    private struct Entry: Codable {
        let sessionId: String
        let runId: String
        let hypothesisId: String
        let location: String
        let message: String
        let timestamp: Int64
        let data: [String: String]
    }

    static func log(runId: String = "pre-fix", hypothesisId: String, location: String, message: String, data: [String: String] = [:]) {
        let entry = Entry(
            sessionId: sessionId,
            runId: runId,
            hypothesisId: hypothesisId,
            location: location,
            message: message,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            data: data,
        )
        guard let lineData = try? JSONEncoder().encode(entry),
              let line = String(data: lineData, encoding: .utf8)
        else { return }
        dbgLogger.info("\(line, privacy: .public)")
    }
}
