import Testing
import Foundation
@testable import TuneMateCore

/// 아주 작은 가짜 X32: 값 저장·조회, /xinfo 응답.
final class FakeX32: @unchecked Sendable {
    var values: [String: OSCMessage.Argument] = [:]
    let lock = NSLock()
    func respond(_ bytes: [UInt8]) -> [[UInt8]] {
        guard let m = OSCMessage.decode(bytes) else { return [] }
        lock.lock(); defer { lock.unlock() }
        if m.address == "/xinfo" { return [OSCMessage("/xinfo", .string("192.168.0.50"), .string("Sanctuary"), .string("X32"), .string("4.06")).encode()] }
        if m.address == "/xremote" || m.address == "/meters" { return [] }
        if let a = m.arguments.first { values[m.address] = a; return [] }
        let v = values[m.address] ?? defaultValue(for: m.address)
        return [OSCMessage(m.address, v).encode()]
    }
    func defaultValue(for addr: String) -> OSCMessage.Argument {
        if addr.hasSuffix("/name") { return .string("") }
        if addr.hasSuffix("/on") || addr.hasSuffix("/type") || addr.hasSuffix("/phantom") { return .int(addr.hasSuffix("/type") ? 2 : 1) }
        if addr.hasSuffix("/fader") || addr.hasSuffix("/level") { return .float(0.75) } // 0 dB
        return .float(0.5)
    }
}

@Suite("OSC mixers")
struct OSCMixerTests {
    @Test func oscEncodeDecodeRoundTrip() {
        let m = OSCMessage("/ch/01/mix/fader", .float(0.75), .int(-3), .string("héllo"), .blob([1, 2, 3, 4, 5]))
        let b = m.encode()
        #expect(b.count % 4 == 0)
        let d = OSCMessage.decode(b)
        #expect(d == m)
        #expect(OSCMessage.decode([1, 2, 3]) == nil)
    }

    @Test func x32FaderCurve() {
        #expect(abs(BehringerDialect.faderToDB(0.75) - 0) < 1e-6)
        #expect(abs(BehringerDialect.faderToDB(1.0) - 10) < 1e-6)
        #expect(abs(BehringerDialect.faderToDB(0.5) - (-10)) < 1e-6)
        #expect(abs(BehringerDialect.faderToDB(0.25) - (-30)) < 1e-6)
        #expect(BehringerDialect.faderToDB(0) == -90)
        for d in [-80.0, -45, -20, -6, 0, 5] {
            #expect(abs(BehringerDialect.faderToDB(BehringerDialect.dbToFader(d)) - d) < 1e-4)
        }
        #expect(abs(BehringerDialect.floatToFreq(BehringerDialect.freqToFloat(1000)) - 1000) < 0.01)
        #expect(abs(BehringerDialect.floatToQ(BehringerDialect.qToFloat(2.0)) - 2.0) < 1e-4)
        #expect(abs(BehringerDialect.floatToGain(BehringerDialect.gainToFloat(-6)) - (-6)) < 1e-4)
    }

    @Test func dialectAddresses() {
        let x = BehringerDialect.x32
        #expect(x.channel(1) == "/ch/01"); #expect(x.bus(3) == "/bus/03"); #expect(x.main == "/main/st"); #expect(x.headamp(1) == "/headamp/000")
        let a = BehringerDialect.xair(channels: 16, buses: 6)
        #expect(a.bus(3) == "/bus/3"); #expect(a.main == "/lr"); #expect(a.headamp(1) == "/headamp/01"); #expect(a.send(2, bus: 1) == "/ch/02/mix/01/level")
    }

    @Test func driverAgainstFakeX32() async throws {
        let fake = FakeX32()
        let t = LoopbackTransport { fake.respond($0) }
        let drv = BehringerOSCDriver(model: .x32, dialect: .x32, transport: t)
        try await drv.connect(host: "192.168.0.50")
        let info = await drv.info
        #expect(info?.model == "X32"); #expect(info?.firmware == "4.06")
        try await drv.setFader(.channel(1), dB: -6)
        try await drv.setMute(.channel(2), on: true)
        try await drv.setEQBand(.mainLR, band: 3, frequencyHz: 250, gainDB: -4.5, q: 2, on: true)
        let s = try await drv.snapshot()
        #expect(abs((s.channel(1)?.faderDB ?? 0) - (-6)) < 0.01)
        #expect(s.channel(2)?.muted == true)
        #expect(s.channel(3)?.muted == false)
        let band = s.main?.eq.first { $0.index == 3 }
        #expect(abs((band?.frequencyHz ?? 0) - 250) < 1)
        #expect(abs((band?.gainDB ?? 0) - (-4.5)) < 0.01)
        #expect(abs((band?.q ?? 0) - 2) < 0.01)
        #expect(s.channels.count == 32); #expect(s.outputs.count == 17)
        await drv.disconnect()
    }

    @Test func meterBlobParsing() {
        // X32: count=2, floats 1.0 (0 dB), 0.1 (-20 dB) LE
        var blob: [UInt8] = [2, 0, 0, 0]
        for f in [Float(1.0), Float(0.1)] { let b = f.bitPattern; blob += [UInt8(b & 0xFF), UInt8((b >> 8) & 0xFF), UInt8((b >> 16) & 0xFF), UInt8(b >> 24)] }
        let v = BehringerOSCDriver.parseMeterBlob(blob, dialect: .x32)!
        #expect(abs(v[0]) < 1e-6); #expect(abs(v[1] - (-20)) < 1e-3)
        // X-Air: int16 1/256 dB: -2560 = -10 dB
        let xa: [UInt8] = [1, 0, 0, 0, 0x00, 0xF6]
        #expect(BehringerOSCDriver.parseMeterBlob(xa, dialect: .xair(channels: 16, buses: 6))?.first == -10)
    }

    @Test func identificationRules() {
        #expect(MixerIdentifier.identifyBehringer(modelString: "X32RACK") == .x32)
        #expect(MixerIdentifier.identifyBehringer(modelString: "XR18") == .xr18)
        #expect(MixerIdentifier.identifyBehringer(modelString: "MR12") == .xr12)
        #expect(MixerIdentifier.identifyBehringer(modelString: "DM24.8") == nil)
        #expect(MixerIdentifier.identifyYamaha(productName: "DM3") == .dm3)
        #expect(MixerIdentifier.identifyYamaha(productName: "DM7") == .dm7)
        let d = MixerIdentifier.fromXInfo(OSCMessage("/xinfo", .string("10.0.0.5"), .string("Hall"), .string("XR16"), .string("1.17")), host: "x", port: 10024)
        #expect(d?.model == .xr16); #expect(d?.host == "10.0.0.5"); #expect(d?.firmware == "1.17"); #expect(d?.confidence == 1.0)
    }

    @Test func yamahaRCPParsingAndGuard() async throws {
        #expect(YamahaRCPDriver.parseValue("OK get MIXER:Current/InCh/Fader/Level 0 0 -1000 \"-10.00\"") == -1000)
        #expect(YamahaRCPDriver.levelToDB(-1000) == -10)
        #expect(YamahaRCPDriver.levelToDB(-32768) == -90)
        #expect(YamahaRCPDriver.dbToLevel(-6.5) == -650)
        #expect(YamahaRCPDriver.parseString("OK get MIXER:Current/InCh/Label/Name 0 0 \"Pastor\"") == "Pastor")
        // 가짜 RCP 서버
        let t = LoopbackTransport { bytes in
            let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "devinfo productname" { return [Array("OK devinfo productname \"DM3\"\n".utf8)] }
            if line == "devinfo version" { return [Array("OK devinfo version 2.10\n".utf8)] }
            if line.hasPrefix("set ") { return [Array(("OK " + line.dropFirst(4) + "\n").utf8)] }
            return [Array("ERROR unknown\n".utf8)]
        }
        let drv = YamahaRCPDriver(model: .dm3, transport: t)
        try await drv.connect(host: "10.0.0.9")
        #expect(await drv.productName == "DM3")
        try await drv.setFader(.channel(1), dB: -10)
        let sent = await t.sent.map { String(decoding: $0, as: UTF8.self) }
        #expect(sent.contains("set MIXER:Current/InCh/Fader/Level 0 0 -1000\n"))
        await #expect(throws: MixerError.self) { try await drv.setPhantom(channel: 1, on: true) } // 미검증 파라미터
    }
}

@Suite("Connection helpers")
struct ConnectionTests {
    @Test func inputLevelAdvice() {
        let quiet = InputLevel.measure([Double](repeating: 0.0001, count: 100))
        #expect(quiet.rmsDB < -60); #expect(quiet.advice.contains("거의 없습니다"))
        let good = InputLevel.measure((0..<4800).map { 0.1 * sin(Double($0) * 0.1) })
        #expect(good.rmsDB > -40 && good.rmsDB < -6); #expect(good.advice.contains("알맞은"))
        let clip = InputLevel.measure([1.0, -1.0, 0.5])
        #expect(clip.clipped)
    }

    @Test func probeRejectsEmptyHostAndUnknownDM248Port() async {
        let r = await MixerProbe.probe(host: "", family: .behringerX32)
        #expect(!r.ok)
        let d = await MixerProbe.probe(host: "192.168.0.9", family: .toppProDM24)
        #expect(!d.ok); #expect(d.message.contains("Phase 0"))
        let m = await MixerProbe.probe(host: "x", family: .mock)
        #expect(m.ok)
    }

    @Test func probeTimesOutOnUnreachableHost() async {
        // 문서용 예약 대역(TEST-NET-1)으로 보내면 응답이 없어 시간 초과로 끝나야 한다.
        let r = await MixerProbe.probe(host: "192.0.2.1", family: .behringerXAir, timeoutSeconds: 1.0)
        #expect(!r.ok); #expect(r.port == 10024)
    }

    @Test func localBroadcastAddressesLookValid() {
        for a in UDPBroadcaster.localBroadcastAddresses() { #expect(a.split(separator: ".").count == 4) }
    }

    @Test func withTimeoutThrows() async {
        await #expect(throws: MixerError.self) {
            try await withTimeout(seconds: 0.1) { try await Task.sleep(nanoseconds: 2_000_000_000) }
        }
    }
}
