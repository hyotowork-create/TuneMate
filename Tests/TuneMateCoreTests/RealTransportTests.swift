import Testing
import Foundation
@testable import TuneMateCore

/// 실제 소켓(127.0.0.1)로 Network.framework 전송 계층을 검증한다.
/// 가짜 X32 는 BSD UDP 소켓으로 /xinfo 와 값 조회에 응답하고, 가짜 Yamaha 는 TCP 로 RCP 줄에 응답한다.
final class FakeUDPX32Server: @unchecked Sendable {
    let fd: Int32
    let port: Int
    private var thread: Thread?
    private let stop = Locked(false)
    var values: [String: OSCMessage.Argument] = [:]
    let lock = NSLock()

    init() {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) } }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        fd = sock
        port = Int(UInt16(bigEndian: bound.sin_port))
        thread = nil
        thread = Thread { [self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            while !stop.get() {
                var from = sockaddr_in(); var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = buf.withUnsafeMutableBufferPointer { b in withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, b.baseAddress, b.count, 0, $0, &flen) } } }
                guard n > 0, let m = OSCMessage.decode(Array(buf[0..<n])) else { continue }
                var reply: OSCMessage?
                lock.lock()
                if m.address == "/xinfo" { reply = OSCMessage("/xinfo", .string("127.0.0.1"), .string("FakeHall"), .string("X32"), .string("4.06")) }
                else if m.address == "/xremote" || m.address == "/meters" { reply = nil }
                else if let a = m.arguments.first { values[m.address] = a }
                else { reply = OSCMessage(m.address, values[m.address] ?? (m.address.hasSuffix("/name") ? .string("") : m.address.hasSuffix("/on") || m.address.hasSuffix("/type") ? .int(m.address.hasSuffix("/type") ? 2 : 1) : .float(0.75))) }
                lock.unlock()
                if let r = reply {
                    let bytes = r.encode()
                    _ = bytes.withUnsafeBufferPointer { b in withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, b.baseAddress, b.count, 0, $0, flen) } } }
                }
            }
            close(fd)
        }
        thread?.start()
    }
    func shutdown() { stop.set(true) }
}

@Suite("Real transport (localhost)")
struct RealTransportTests {
    @Test func x32DriverOverRealUDP() async throws {
        let server = FakeUDPX32Server()
        defer { server.shutdown() }
        var dialect = BehringerDialect.x32
        dialect = BehringerDialect(kind: .x32, port: server.port, channelCount: 2, busCount: 1, mainEQBands: 6)
        var model = MixerModel.x32; model.channelCount = 2; model.auxCount = 1
        let drv = BehringerOSCDriver(model: model, dialect: dialect, transport: NWByteTransport(kind: .udp))
        try await drv.connect(host: "127.0.0.1")
        #expect(await drv.info?.model == "X32")
        try await drv.setFader(.channel(1), dB: -12)
        try await drv.setMute(.channel(2), on: true)
        let s = try await drv.snapshot()
        #expect(abs((s.channel(1)?.faderDB ?? 0) - (-12)) < 0.05)
        #expect(s.channel(2)?.muted == true)
        #expect(s.channels.count == 2)
        await drv.disconnect()
    }

    @Test func probeOverRealUDPIdentifiesModel() async throws {
        let server = FakeUDPX32Server()
        defer { server.shutdown() }
        // MixerProbe 는 표준 포트를 쓰므로 여기서는 OSCClient 로 직접 /xinfo 를 확인한다.
        let client = OSCClient(transport: NWByteTransport(kind: .udp))
        try await client.open(host: "127.0.0.1", port: server.port)
        let r = try await client.request(OSCMessage("/xinfo"))
        await client.close()
        let d = MixerIdentifier.fromXInfo(r, host: "127.0.0.1", port: server.port)
        #expect(d?.model == .x32); #expect(d?.firmware == "4.06"); #expect(d?.reportedName == "FakeHall")
    }

    @Test func udpRequestToClosedPortTimesOutQuickly() async throws {
        let client = OSCClient(transport: NWByteTransport(kind: .udp))
        await client.setTimeout(seconds: 0.5)
        try await client.open(host: "127.0.0.1", port: 1) // 아무도 듣지 않는 포트
        let t0 = Date()
        await #expect(throws: MixerError.self) { _ = try await client.request(OSCMessage("/xinfo")) }
        #expect(Date().timeIntervalSince(t0) < 3)
        await client.close()
    }

    @Test func tcpOpenToClosedPortFails() async throws {
        let t = NWByteTransport(kind: .tcp)
        let t0 = Date()
        await #expect(throws: MixerError.self) { try await withTimeout(seconds: 3) { try await t.open(host: "127.0.0.1", port: 1) } }
        #expect(Date().timeIntervalSince(t0) < 4)
        await t.close()
    }
}
