import Foundation
@testable import NwVpnWire
import XCTest

final class GoldenTests: XCTestCase {
    func testGoldenFramesJSON() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("testdata/golden_frames.json")
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let frames = obj["frames"] as! [[String: Any]]
        for item in frames {
            let name = item["name"] as! String
            let hex = (item["hex"] as! String).replacingOccurrences(of: " ", with: "")
            let expect = item["expect"] as! [String: Any]
            let bytes = try Self.hexDecode(hex)
            let (t, ln) = try NwFraming.decodeHeader(bytes)
            XCTAssertEqual(Int(t.rawValue), expect["msg_type"] as! Int, name)
            XCTAssertEqual(bytes.count, NwFraming.headerSize + ln, name)
            let payload = bytes.subdata(in: NwFraming.headerSize..<bytes.count)
            switch t {
            case .clientHello:
                let mtu = Int(UInt16(payload[0]) << 8 | UInt16(payload[1]))
                let caps = (UInt32(payload[2]) << 24) | (UInt32(payload[3]) << 16) | (UInt32(payload[4]) << 8) | UInt32(payload[5])
                let ch = expect["client_hello"] as! [String: Any]
                XCTAssertEqual(mtu, ch["mtu"] as! Int, name)
                XCTAssertEqual(UInt64(caps), UInt64(ch["caps"] as! Int), name)
            case .serverHello:
                let mtu = Int(UInt16(payload[0]) << 8 | UInt16(payload[1]))
                let sh = expect["server_hello"] as! [String: Any]
                XCTAssertEqual(mtu, sh["mtu"] as! Int, name)
            case .assignTunnel:
                let a = try NwFraming.decodeAssignTunnel(payload)
                let w = expect["assign_tunnel"] as! [String: Any]
                let ipStr = Self.ipv4String(a.ipv4)
                XCTAssertEqual(ipStr, w["ipv4"] as! String, name)
                XCTAssertEqual(Int(a.flags), w["flags"] as! Int, name)
                let dns = w["dns"] as! [String]
                XCTAssertEqual(a.dns.count, dns.count, name)
                for i in 0..<a.dns.count {
                    XCTAssertEqual(Self.ipv4String(a.dns[i]), dns[i], name)
                }
            case .keepalive:
                break
            case .error:
                let (code, msg) = try NwFraming.decodeError(payload)
                let e = expect["error"] as! [String: Any]
                XCTAssertEqual(Int(code), e["code"] as! Int, name)
                XCTAssertEqual(msg, e["msg"] as! String, name)
            case .disconnect:
                let (reason, msg) = try NwFraming.decodeDisconnect(payload)
                let d = expect["disconnect"] as! [String: Any]
                XCTAssertEqual(Int(reason), d["reason"] as! Int, name)
                XCTAssertEqual(msg, d["msg"] as! String, name)
            default:
                XCTFail("unhandled \(t) in \(name)")
            }
        }
    }

    private static func hexDecode(_ s: String) throws -> Data {
        var out = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            let byte = UInt8(s[i..<j], radix: 16)!
            out.append(byte)
            i = j
        }
        return out
    }

    private static func ipv4String(_ d: Data) -> String {
        precondition(d.count == 4)
        return "\(d[0]).\(d[1]).\(d[2]).\(d[3])"
    }
}
