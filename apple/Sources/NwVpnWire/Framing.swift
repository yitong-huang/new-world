import Foundation

public enum NwMsgType: UInt8 {
    case clientHello = 1
    case serverHello = 2
    case assignTunnel = 3
    case data = 4
    case keepalive = 5
    case error = 6
    case disconnect = 7
    case authCredentials = 8
}

/// ClientHello.caps: bit1 means AuthCredentials frame follows.
public let NwCapAuthNext: UInt32 = 1 << 1

public struct NwFrame: Equatable {
    public var type: NwMsgType
    public var payload: Data
}

public enum NwFramingError: Error {
    case badMagic
    case badVersion
    case badLength
    case badType
    case shortBuffer
}

public enum NwFraming {
    public static let headerSize = 12

    public static func encodeFrame(type: NwMsgType, payload: Data) -> Data {
        var d = Data()
        d.append(contentsOf: [0x4E, 0x57, 0x30, 0x31])
        d.append(contentsOf: [0, 1]) // version BE
        d.append(type.rawValue)
        d.append(0)
        var lenBE = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &lenBE) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }

    public static func decodeHeader(_ prefix: Data) throws -> (NwMsgType, Int) {
        guard prefix.count >= headerSize else { throw NwFramingError.shortBuffer }
        if prefix[0] != 0x4E || prefix[1] != 0x57 || prefix[2] != 0x30 || prefix[3] != 0x31 {
            throw NwFramingError.badMagic
        }
        let ver = (UInt16(prefix[4]) << 8) | UInt16(prefix[5])
        if ver != 1 { throw NwFramingError.badVersion }
        guard let t = NwMsgType(rawValue: prefix[6]) else { throw NwFramingError.badType }
        if prefix[7] != 0 { throw NwFramingError.badVersion }
        let len = Int(
            (UInt32(prefix[8]) << 24)
                | (UInt32(prefix[9]) << 16)
                | (UInt32(prefix[10]) << 8)
                | UInt32(prefix[11]),
        )
        if len < 0 || len > 1_048_576 - headerSize { throw NwFramingError.badLength }
        return (t, len)
    }

    public static func decodeFrame(_ buf: Data) throws -> NwFrame {
        let (t, ln) = try decodeHeader(buf)
        guard buf.count == headerSize + ln else { throw NwFramingError.shortBuffer }
        let payload = buf.subdata(in: headerSize..<buf.count)
        return NwFrame(type: t, payload: payload)
    }

    public struct AssignTunnel {
        public var ipv4: Data // 4 bytes
        public var dns: [Data]
        public var flags: UInt8
    }

    public static func decodeAssignTunnel(_ payload: Data) throws -> AssignTunnel {
        guard payload.count >= 4 + 1 + 1 else { throw NwFramingError.shortBuffer }
        let ipv4 = payload.subdata(in: 0..<4)
        let n = Int(payload[4])
        guard n >= 0 && n <= 4 else { throw NwFramingError.badLength }
        guard payload.count >= 5 + 4 * n + 1 else { throw NwFramingError.shortBuffer }
        var dns: [Data] = []
        for i in 0..<n {
            let s = 5 + 4 * i
            dns.append(payload.subdata(in: s..<(s + 4)))
        }
        let flags = payload[5 + 4 * n]
        return AssignTunnel(ipv4: ipv4, dns: dns, flags: flags)
    }

    public static func decodeError(_ payload: Data) throws -> (UInt16, String) {
        guard payload.count >= 4 else { throw NwFramingError.shortBuffer }
        let code = UInt16(payload[0]) << 8 | UInt16(payload[1])
        let ml = Int(UInt16(payload[2]) << 8 | UInt16(payload[3]))
        guard payload.count >= 4 + ml else { throw NwFramingError.shortBuffer }
        let msg = String(data: payload.subdata(in: 4..<(4 + ml)), encoding: .utf8) ?? ""
        return (code, msg)
    }

    public static func encodeClientHello(mtu: UInt16, caps: UInt32) -> Data {
        var d = Data()
        var mtuBE = mtu.bigEndian
        var capsBE = caps.bigEndian
        withUnsafeBytes(of: &mtuBE) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: &capsBE) { d.append(contentsOf: $0) }
        return d
    }

    public static func encodeAuthCredentials(user: String, pass: String) throws -> Data {
        let ud = Data(user.utf8)
        let pd = Data(pass.utf8)
        guard ud.count <= 512, pd.count <= 512 else { throw NwFramingError.badLength }
        var d = Data()
        var ul = UInt16(ud.count).bigEndian
        var pl = UInt16(pd.count).bigEndian
        withUnsafeBytes(of: &ul) { d.append(contentsOf: $0) }
        d.append(ud)
        withUnsafeBytes(of: &pl) { d.append(contentsOf: $0) }
        d.append(pd)
        return d
    }

    public static func decodeDisconnect(_ payload: Data) throws -> (UInt8, String) {
        guard payload.count >= 3 else { throw NwFramingError.shortBuffer }
        let reason = payload[0]
        let ml = Int(UInt16(payload[1]) << 8 | UInt16(payload[2]))
        guard payload.count >= 3 + ml else { throw NwFramingError.shortBuffer }
        let msg = String(data: payload.subdata(in: 3..<(3 + ml)), encoding: .utf8) ?? ""
        return (reason, msg)
    }
}
