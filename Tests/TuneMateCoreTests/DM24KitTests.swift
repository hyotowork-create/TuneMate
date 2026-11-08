import Testing
import Foundation
@testable import TuneMateCore

@Suite("DM24Kit")
struct DM24KitTests {
    static let verifiedSpec = """
    spec_version: 1
    status: verified
    model: TOPP PRO DM24.8
    firmware: "1.0.0"
    transport: { kind: tcp, port: 50000, keepalive_interval_ms: 0, keepalive_bytes: [] }
    handshake: { send: [0x01, 0x02], expect_prefix: [] }
    frame:
      header: [0xAA, 0x55]
      length_field_size: 1
      length_includes_header: false
      address_size: 2
      value_size: 2
      byte_order: little
      checksum: xor8
    parameters:
      channel.fader: { address_base: 0x0000, stride: 0x0040, encoding: fader_db, verified: true }
      channel.mute:  { address_base: 0x0001, stride: 0x0040, encoding: bool, verified: true }
      channel.eq.freq: { address_base: 0x0010, stride: 0x0040, band_stride: 0x0004, encoding: freq_log, verified: true }
      channel.eq.gain: { address_base: 0x0011, stride: 0x0040, band_stride: 0x0004, encoding: eq_gain, verified: true }
      channel.eq.q: { address_base: 0x0012, stride: 0x0040, band_stride: 0x0004, encoding: q_log, verified: true }
      channel.eq.band_on: { address_base: 0x0013, stride: 0x0040, band_stride: 0x0004, encoding: bool, verified: true }
      main.fader: { address_base: 0x0A00, stride: 0, encoding: fader_db, verified: false }
    encodings:
      fader_db: { kind: linear, min: -90, max: 10, min_raw: 0, max_raw: 1000 }
      freq_log: { kind: log, min: 20, max: 20000, min_raw: 0, max_raw: 200 }
      eq_gain: { kind: linear, min: -15, max: 15, min_raw: 0, max_raw: 60 }
      q_log: { kind: log, min: 0.3, max: 10, min_raw: 0, max_raw: 71 }
      bool: { kind: bool }
    notes:
      - "test"
    """

    @Test func yamlParsesNestedStructures() throws {
        let y = try MiniYAML.parse(Self.verifiedSpec)
        #expect(y["status"]?.stringValue == "verified")
        #expect(y["frame"]?["header"]?.intArray == [0xAA, 0x55])
        #expect(y["transport"]?["port"]?.intValue == 50000)
        #expect(y["parameters"]?["channel.eq.freq"]?["band_stride"]?.intValue == 4)
        #expect(y["notes"]?.arrayValue?.first?.stringValue == "test")
        #expect(y["frame"]?["length_includes_header"]?.boolValue == false)
    }

    @Test func bundledSpecLoadsAndIsUnverified() throws {
        let spec = try ProtocolSpec.bundled()
        #expect(spec.status == .unverified)
        #expect(spec.parameters["channel.fader"] != nil)
        #expect(spec.encodings["freq_log"]?.kind == .log)
        #expect(!spec.notes.isEmpty)
    }

    @Test func encodingsRoundTrip() throws {
        let spec = try ProtocolSpec.parse(Self.verifiedSpec)
        let f = try spec.encoding("freq_log")
        #expect(f.encode(20) == 0); #expect(f.encode(20000) == 200)
        #expect(abs(f.decode(100) - 632.46) < 0.5) // 20*1000^0.5
        let g = try spec.encoding("eq_gain")
        #expect(g.encode(0) == 30); #expect(g.encode(-6) == 18); #expect(g.decode(18) == -6)
        let fd = try spec.encoding("fader_db")
        #expect(fd.encode(-90) == 0); #expect(fd.encode(10) == 1000); #expect(fd.encode(0) == 900)
    }

    @Test func frameEncodeDecodeWithChecksum() throws {
        let spec = try ProtocolSpec.parse(Self.verifiedSpec)
        let codec = FrameCodec(spec: spec)
        let bytes = try codec.encodeSet(parameter: "channel.eq.gain", index: 0, band: 1, value: -6) // CH1 band2
        // AA 55 len(4) addr(0x0015 LE) raw(18 LE) xor
        #expect(Array(bytes.prefix(2)) == [0xAA, 0x55])
        #expect(bytes[2] == 5) // 4 body + 1 checksum
        #expect(bytes[3] == 0x15 && bytes[4] == 0x00)
        #expect(bytes[5] == 18 && bytes[6] == 0)
        let dec = codec.decode(bytes)
        #expect(dec?.address == 0x15); #expect(dec?.raw == 18)
        var corrupted = bytes; corrupted[5] = 19
        #expect(codec.decode(corrupted) == nil)
    }

    @Test func driverBlocksWritesWhenUnverifiedAndWritesWhenVerified() async throws {
        let unverified = try ProtocolSpec.bundled()
        let t1 = LoopbackTransport()
        let d1 = DM24Driver(spec: unverified, transport: t1)
        try await d1.connect(host: "127.0.0.1")
        #expect(d1.model.protocolStatus == .unverified)
        await #expect(throws: MixerError.self) { try await d1.setFader(.channel(1), dB: -10) }

        let verified = try ProtocolSpec.parse(Self.verifiedSpec)
        let t2 = LoopbackTransport()
        let d2 = DM24Driver(spec: verified, transport: t2)
        try await d2.connect(host: "127.0.0.1")
        #expect(d2.model.protocolStatus == .reverseEngineered)
        try await d2.setFader(.channel(2), dB: 0)
        let sent = await t2.sent
        #expect(sent.count == 2) // handshake + fader
        #expect(sent[0] == [0x01, 0x02])
        let dec = FrameCodec(spec: verified).decode(sent[1])
        #expect(dec?.address == 0x40); #expect(dec?.raw == 900)
        let s = try await d2.snapshot()
        #expect(s.channel(2)?.faderDB == 0)
        // 미검증 파라미터는 막힌다
        await #expect(throws: MixerError.self) { try await d2.setFader(.mainLR, dB: -3) }
        // 수신 프레임이 캐시에 반영된다 (CH1 mute on)
        let frame = FrameCodec(spec: verified).frame(address: 0x0001, raw: 1)
        await t2.inject(frame)
        try await Task.sleep(nanoseconds: 50_000_000)
        let s2 = try await d2.snapshot()
        #expect(s2.channel(1)?.muted == true)
    }

    @Test func firmwareMismatchBlocksWrites() async throws {
        let verified = try ProtocolSpec.parse(Self.verifiedSpec)
        let d = DM24Driver(spec: verified, transport: LoopbackTransport())
        try await d.connect(host: "x")
        await d.setReportedFirmware("2.0.0")
        await #expect(throws: MixerError.self) { try await d.setMute(.channel(1), on: true) }
    }
}

extension DM24Driver {
    func setReportedFirmware(_ s: String) { reportedFirmware = s }
}
