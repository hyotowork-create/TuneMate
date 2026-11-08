import Foundation

/// Behringer/Midas OSC 방언 (X32·M32 vs X-Air·MR 시리즈 차이).
public struct BehringerDialect: Sendable, Equatable {
    public enum Kind: String, Sendable { case x32, xair }
    public let kind: Kind
    public let port: Int
    public let channelCount: Int
    public let busCount: Int
    public let mainEQBands: Int

    public static let x32 = BehringerDialect(kind: .x32, port: 10023, channelCount: 32, busCount: 16, mainEQBands: 6)
    public static func xair(channels: Int, buses: Int) -> BehringerDialect { BehringerDialect(kind: .xair, port: 10024, channelCount: channels, busCount: buses, mainEQBands: 6) }

    public func channel(_ n: Int) -> String { String(format: "/ch/%02d", n) }
    public func bus(_ n: Int) -> String { kind == .x32 ? String(format: "/bus/%02d", n) : "/bus/\(n)" }
    public var main: String { kind == .x32 ? "/main/st" : "/lr" }
    public func headamp(_ ch: Int) -> String { kind == .x32 ? String(format: "/headamp/%03d", ch - 1) : String(format: "/headamp/%02d", ch) }
    public func send(_ ch: Int, bus: Int) -> String { String(format: "/ch/%02d/mix/%02d/level", ch, bus) }

    public func base(_ t: EQTarget) throws -> String {
        switch t {
        case .channel(let n): return channel(n)
        case .aux(let n): return bus(n)
        case .mainLR: return main
        case .dca(let n): return String(format: "/dca/%d", n)
        case .fxReturn: throw MixerError.unsupported("fx return")
        }
    }

    // MARK: 값 변환 (X32 OSC 문서의 페이더 곡선·로그 스케일)
    public static func faderToDB(_ f: Float) -> Double {
        let x = Double(f)
        if x >= 0.5 { return x * 40 - 30 }
        if x >= 0.25 { return x * 80 - 50 }
        if x >= 0.0625 { return x * 160 - 70 }
        if x > 0 { return x * 480 - 90 }
        return -90
    }
    public static func dbToFader(_ d: Double) -> Float {
        let v: Double
        if d <= -90 { v = 0 }
        else if d < -60 { v = (d + 90) / 480 }
        else if d < -30 { v = (d + 70) / 160 }
        else if d < -10 { v = (d + 50) / 80 }
        else { v = (d + 30) / 40 }
        return Float(min(1, max(0, v)))
    }
    public static func freqToFloat(_ hz: Double) -> Float { Float(min(1, max(0, log10(hz / 20) / 3))) }
    public static func floatToFreq(_ f: Float) -> Double { 20 * pow(10, 3 * Double(f)) }
    public static func gainToFloat(_ g: Double) -> Float { Float(min(1, max(0, (g + 15) / 30))) }
    public static func floatToGain(_ f: Float) -> Double { Double(f) * 30 - 15 }
    public static func qToFloat(_ q: Double) -> Float { Float(min(1, max(0, log(10 / q) / log(10 / 0.3)))) }
    public static func floatToQ(_ f: Float) -> Double { 10 / pow(10 / 0.3, Double(f)) }
    public static func headampToFloat(_ g: Double) -> Float { Float(min(1, max(0, (g + 12) / 72))) }
    public static func floatToHeadamp(_ f: Float) -> Double { Double(f) * 72 - 12 }
    public static func eqTypeCode(_ t: EQFilterType) -> Int32 {
        switch t { case .lowCut: return 0; case .lowShelf: return 1; case .peaking, .notch: return 2; case .highShelf: return 4; case .highCut: return 5 }
    }
    public static func eqType(code: Int) -> EQFilterType {
        switch code { case 0: return .lowCut; case 1: return .lowShelf; case 4: return .highShelf; case 5: return .highCut; default: return .peaking }
    }
}

/// X32/M32/X-Air/MR OSC 드라이버. 공개 사양이라 쓰기가 허용된다.
public actor BehringerOSCDriver: MixerDriver {
    public nonisolated let model: MixerModel
    public let dialect: BehringerDialect
    private let client: OSCClient
    private var _status: ConnectionStatus = .disconnected
    private var remoteTask: Task<Void, Never>?
    public var info: (ip: String, name: String, model: String, firmware: String)?

    public init(model: MixerModel, dialect: BehringerDialect, transport: any ByteTransport) {
        self.model = model
        self.dialect = dialect
        self.client = OSCClient(transport: transport)
    }

    public var status: ConnectionStatus { _status }

    public func connect(host: String) async throws {
        _status = .connecting
        do {
            try await client.open(host: host, port: dialect.port)
            await client.setTimeout(seconds: 2.5)
            let r = try await client.request(OSCMessage("/xinfo"))
            await client.setTimeout(seconds: 0.8)
            let s = r.arguments.compactMap(\.stringValue)
            if s.count >= 4 { info = (s[0], s[1], s[2], s[3]) }
            _status = .connected
            startXRemote()
        } catch {
            _status = .failed("\(error)")
            await client.close()
            throw error
        }
    }

    /// 10초마다 /xremote 를 갱신해 변경 알림·미터를 계속 받는다.
    private func startXRemote() {
        remoteTask?.cancel()
        remoteTask = Task { [client] in
            while !Task.isCancelled {
                try? await client.send(OSCMessage("/xremote"))
                try? await Task.sleep(nanoseconds: 9_000_000_000)
            }
        }
    }

    public func disconnect() async {
        remoteTask?.cancel()
        await client.close()
        _status = .disconnected
    }

    private func require() throws { guard _status == .connected else { throw MixerError.notConnected } }

    /// 응답 없는 주소를 오류 메시지에 남긴다 (현장 진단용).
    private func ask(_ addr: String) async throws -> OSCMessage {
        do { return try await client.request(OSCMessage(addr)) }
        catch MixerError.timeout { throw MixerError.transport("\(addr) 응답 없음 (시간 초과)") }
    }
    private func getFloat(_ addr: String) async throws -> Float {
        guard let v = try await ask(addr).arguments.first?.floatValue else { throw MixerError.transport("no value for \(addr)") }
        return v
    }
    private func getInt(_ addr: String) async throws -> Int {
        guard let v = try await ask(addr).arguments.first?.intValue else { throw MixerError.transport("no value for \(addr)") }
        return v
    }
    private func getString(_ addr: String) async throws -> String {
        try await ask(addr).arguments.first?.stringValue ?? ""
    }

    private func readEQ(_ base: String, bands: Int) async throws -> [EQBand] {
        var out: [EQBand] = []
        for b in 1...bands {
            let p = "\(base)/eq/\(b)"
            let type = try await getInt("\(p)/type")
            let f = try await getFloat("\(p)/f"), g = try await getFloat("\(p)/g"), q = try await getFloat("\(p)/q")
            let gain = BehringerDialect.floatToGain(g)
            out.append(EQBand(index: b, type: BehringerDialect.eqType(code: type), frequencyHz: BehringerDialect.floatToFreq(f), gainDB: gain, q: BehringerDialect.floatToQ(q), enabled: abs(gain) > 0.05))
        }
        return out
    }

    public func snapshot() async throws -> MixerState {
        try require()
        var channels: [ChannelState] = []
        for n in 1...dialect.channelCount {
            let b = dialect.channel(n)
            let name = try await getString("\(b)/config/name")
            let fader = BehringerDialect.faderToDB(try await getFloat("\(b)/mix/fader"))
            let on = try await getInt("\(b)/mix/on")
            let pan = Double(try await getFloat("\(b)/mix/pan")) * 2 - 1
            let eqOn = try await getInt("\(b)/eq/on")
            let eq = try await readEQ(b, bands: 4)
            var sends: [Double] = []
            for bus in 1...dialect.busCount { sends.append(BehringerDialect.faderToDB(try await getFloat(dialect.send(n, bus: bus)))) }
            var gain = 0.0, phantom = false
            if let g = try? await getFloat("\(dialect.headamp(n))/gain") { gain = BehringerDialect.floatToHeadamp(g) }
            if let p = try? await getInt("\(dialect.headamp(n))/phantom") { phantom = p != 0 }
            channels.append(ChannelState(index: n, name: name, faderDB: fader, muted: on == 0, preampGainDB: gain, phantomOn: phantom, pan: pan, eqOn: eqOn != 0, eq: eq, auxSendsDB: sends))
        }
        var outputs: [OutputState] = []
        let m = dialect.main
        outputs.append(OutputState(target: .mainLR, name: "Main L/R", faderDB: BehringerDialect.faderToDB(try await getFloat("\(m)/mix/fader")),
                                   muted: (try await getInt("\(m)/mix/on")) == 0, eqOn: (try await getInt("\(m)/eq/on")) != 0,
                                   eq: try await readEQ(m, bands: dialect.mainEQBands)))
        for n in 1...dialect.busCount {
            let b = dialect.bus(n)
            outputs.append(OutputState(target: .aux(n), name: try await getString("\(b)/config/name"), faderDB: BehringerDialect.faderToDB(try await getFloat("\(b)/mix/fader")),
                                       muted: (try await getInt("\(b)/mix/on")) == 0, eqOn: (try await getInt("\(b)/eq/on")) != 0, eq: try await readEQ(b, bands: 6)))
        }
        return MixerState(model: model, firmwareVersion: info?.firmware, channels: channels, outputs: outputs)
    }

    public func meters() async -> AsyncStream<Levels>? {
        guard _status == .connected else { return nil }
        let client = self.client
        let dialect = self.dialect
        return AsyncStream { continuation in
            let task = Task {
                let subscribe = Task {
                    while !Task.isCancelled {
                        try? await client.send(OSCMessage("/meters", .string("/meters/1"), .int(0)))
                        try? await Task.sleep(nanoseconds: 9_000_000_000)
                    }
                }
                for await m in client.unsolicitedMessages where m.address == "/meters/1" {
                    guard let blob = m.arguments.first?.blobValue, let levels = Self.parseMeterBlob(blob, dialect: dialect) else { continue }
                    continuation.yield(Levels(channelsDB: Array(levels.prefix(dialect.channelCount)), outputsDB: [:]))
                }
                subscribe.cancel()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// X32: int32 LE count + float32 LE (선형 진폭). X-Air: int32 LE count + int16 LE (1/256 dB).
    public static func parseMeterBlob(_ blob: [UInt8], dialect: BehringerDialect) -> [Double]? {
        guard blob.count >= 4 else { return nil }
        let count = Int(UInt32(blob[0]) | UInt32(blob[1]) << 8 | UInt32(blob[2]) << 16 | UInt32(blob[3]) << 24)
        var out: [Double] = []
        if dialect.kind == .x32 {
            guard blob.count >= 4 + count * 4 else { return nil }
            for i in 0..<count {
                let o = 4 + i * 4
                let bits = UInt32(blob[o]) | UInt32(blob[o + 1]) << 8 | UInt32(blob[o + 2]) << 16 | UInt32(blob[o + 3]) << 24
                out.append(Decibel.fromAmplitude(Double(Float(bitPattern: bits))))
            }
        } else {
            guard blob.count >= 4 + count * 2 else { return nil }
            for i in 0..<count {
                let o = 4 + i * 2
                let v = Int16(bitPattern: UInt16(blob[o]) | UInt16(blob[o + 1]) << 8)
                out.append(Double(v) / 256)
            }
        }
        return out
    }

    public func setFader(_ target: EQTarget, dB: Double) async throws {
        try require(); try await client.send(OSCMessage("\(try dialect.base(target))/mix/fader", .float(BehringerDialect.dbToFader(dB))))
    }
    public func setMute(_ target: EQTarget, on: Bool) async throws {
        try require(); try await client.send(OSCMessage("\(try dialect.base(target))/mix/on", .int(on ? 0 : 1)))
    }
    public func setPreampGain(channel: Int, dB: Double) async throws {
        try require(); try await client.send(OSCMessage("\(dialect.headamp(channel))/gain", .float(BehringerDialect.headampToFloat(dB))))
    }
    public func setPan(channel: Int, pan: Double) async throws {
        try require(); try await client.send(OSCMessage("\(dialect.channel(channel))/mix/pan", .float(Float((pan + 1) / 2))))
    }
    public func setEQBand(_ target: EQTarget, band: Int, frequencyHz: Double, gainDB: Double, q: Double, on: Bool) async throws {
        try require()
        let p = "\(try dialect.base(target))/eq/\(band)"
        try await client.send(OSCMessage("\(p)/type", .int(BehringerDialect.eqTypeCode(.peaking))))
        try await client.send(OSCMessage("\(p)/f", .float(BehringerDialect.freqToFloat(frequencyHz))))
        try await client.send(OSCMessage("\(p)/g", .float(BehringerDialect.gainToFloat(on ? gainDB : 0))))
        try await client.send(OSCMessage("\(p)/q", .float(BehringerDialect.qToFloat(q))))
    }
    public func setEQEnabled(_ target: EQTarget, on: Bool) async throws {
        try require(); try await client.send(OSCMessage("\(try dialect.base(target))/eq/on", .int(on ? 1 : 0)))
    }
    public func setAuxSend(channel: Int, aux: Int, dB: Double) async throws {
        try require(); try await client.send(OSCMessage(dialect.send(channel, bus: aux), .float(BehringerDialect.dbToFader(dB))))
    }
    public func setDelay(output: EQTarget, ms: Double) async throws {
        throw MixerError.unsupported("출력 딜레이는 /outputs/... 라우팅 확인 뒤 지원")
    }
    public func setPhantom(channel: Int, on: Bool) async throws {
        try require(); try await client.send(OSCMessage("\(dialect.headamp(channel))/phantom", .int(on ? 1 : 0)))
    }
    public func saveScene(number: Int, name: String) async throws {
        try require()
        if dialect.kind == .x32 { try await client.send(OSCMessage("/save", .string("scene"), .int(Int32(number)), .string(name), .string(""))) }
        else { try await client.send(OSCMessage("/-snap/save", .int(Int32(number)))); try await client.send(OSCMessage(String(format: "/-snap/%02d/name", number), .string(name))) }
    }
    public func recallScene(number: Int) async throws {
        try require()
        if dialect.kind == .x32 { try await client.send(OSCMessage("/-action/goscene", .int(Int32(number)))) }
        else { try await client.send(OSCMessage("/-snap/load", .int(Int32(number)))) }
    }
}
