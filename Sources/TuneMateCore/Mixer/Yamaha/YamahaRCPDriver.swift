import Foundation

/// Yamaha 원격 제어 프로토콜(RCP, TCP 49280, 텍스트 줄 단위) 드라이버 — TF·DM3·DM7·CL·QL 계열 공통.
/// 페이더·온/오프·센드·이름은 공개 문서(TF 시리즈 RCP) 기준. EQ·게인·팬텀 주소는 기기별 확인 전까지 쓰기 차단.
public actor YamahaRCPDriver: MixerDriver {
    public nonisolated let model: MixerModel
    public static let port = 49280
    private let transport: any ByteTransport
    private var _status: ConnectionStatus = .disconnected
    private var buffer: [UInt8] = []
    private var pending: [LineWaiter] = []
    private var receiveTask: Task<Void, Never>?
    public private(set) var productName: String?
    public private(set) var firmware: String?
    /// 기기에서 확인된 파라미터만 쓰기 허용
    public var verifiedParameters: Set<String> = ["InCh/Fader/Level", "InCh/Fader/On", "InCh/ToMix/Level", "St/Fader/Level", "St/Fader/On", "Mix/Fader/Level", "Mix/Fader/On", "InCh/Label/Name"]

    public init(model: MixerModel, transport: any ByteTransport) {
        self.model = model
        self.transport = transport
    }

    public var status: ConnectionStatus { _status }

    public func connect(host: String) async throws {
        _status = .connecting
        do {
            try await transport.open(host: host, port: Self.port)
            startReceive()
            _status = .connected
            productName = try await command("devinfo productname").split(separator: " ").last.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            firmware = try? await command("devinfo version").split(separator: " ").last.map(String.init)
        } catch {
            _status = .failed("\(error)")
            throw error
        }
    }

    public func disconnect() async {
        receiveTask?.cancel()
        await transport.close()
        _status = .disconnected
    }

    private func startReceive() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.transport.incoming
            for await bytes in stream { await self.handle(bytes) }
        }
    }

    private func handle(_ bytes: [UInt8]) {
        buffer += bytes
        while let nl = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<nl], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...nl)
            guard !line.isEmpty, !line.hasPrefix("NOTIFY") else { continue }
            if !pending.isEmpty { pending.removeFirst().resume(.success(line)) }
        }
    }

    /// 한 줄 명령 → 한 줄 응답 ("OK ..." / "ERROR ..."). 1.5초 안에 답이 없으면 대기자를 정리하고 throw.
    public func command(_ line: String) async throws -> String {
        guard _status == .connected || _status == .connecting else { throw MixerError.notConnected }
        let reply: String = try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            let done = Locked(false)
            let w = LineWaiter { r in if done.swap(true) == false { c.resume(with: r) } }
            pending.append(w)
            Task { [transport] in try? await transport.send(Array((line + "\n").utf8)) }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await self?.expire(w)
            }
        }
        if reply.hasPrefix("ERROR") { throw MixerError.transport(reply) }
        return reply
    }

    final class LineWaiter: @unchecked Sendable {
        let id = UUID()
        let resume: (Result<String, Error>) -> Void
        init(_ r: @escaping (Result<String, Error>) -> Void) { resume = r }
    }
    private func expire(_ w: LineWaiter) {
        if let i = pending.firstIndex(where: { $0.id == w.id }) { pending.remove(at: i); w.resume(.failure(MixerError.timeout)) }
    }

    // MARK: 값 변환 — RCP 레벨은 1/100 dB, -32768 = -∞
    public static func levelToDB(_ v: Int) -> Double { v <= -32768 ? -90 : Double(v) / 100 }
    public static func dbToLevel(_ d: Double) -> Int { d <= -90 ? -32768 : Int((d * 100).rounded()) }

    /// "OK get MIXER:Current/InCh/Fader/Level 0 0 -1000 \"-10.00\"" → -1000
    public static func parseValue(_ reply: String) -> Int? {
        let parts = reply.split(separator: " ")
        guard parts.count >= 6 else { return nil }
        return Int(parts[5])
    }
    public static func parseString(_ reply: String) -> String? {
        guard let q1 = reply.firstIndex(of: "\""), let q2 = reply.lastIndex(of: "\""), q1 < q2 else { return nil }
        return String(reply[reply.index(after: q1)..<q2])
    }

    private func guardWrite(_ param: String) throws {
        guard _status == .connected else { throw MixerError.notConnected }
        guard verifiedParameters.contains(param) else { throw MixerError.protocolUnverified("Yamaha RCP 파라미터 \(param) — 기기에서 주소 확인 뒤 허용") }
    }

    private func set(_ param: String, _ a: Int, _ b: Int, _ value: Int) async throws {
        try guardWrite(param)
        _ = try await command("set MIXER:Current/\(param) \(a) \(b) \(value)")
    }
    private func get(_ param: String, _ a: Int, _ b: Int) async throws -> Int {
        guard let v = Self.parseValue(try await command("get MIXER:Current/\(param) \(a) \(b)")) else { throw MixerError.transport("bad reply for \(param)") }
        return v
    }

    public func snapshot() async throws -> MixerState {
        guard _status == .connected else { throw MixerError.notConnected }
        var channels: [ChannelState] = []
        let chCount = min(model.channelCount, 64)
        for n in 0..<chCount {
            let fader = Self.levelToDB(try await get("InCh/Fader/Level", n, 0))
            let on = try await get("InCh/Fader/On", n, 0)
            let name = Self.parseString(try await command("get MIXER:Current/InCh/Label/Name \(n) 0")) ?? ""
            var sends: [Double] = []
            for mix in 0..<min(model.auxCount, 16) { sends.append(Self.levelToDB((try? await get("InCh/ToMix/Level", n, mix)) ?? -32768)) }
            let eq = (1...4).map { EQBand(index: $0, frequencyHz: [100.0, 500, 2000, 8000][$0 - 1], gainDB: 0, q: 1, enabled: false) } // EQ 읽기 주소 확인 전
            channels.append(ChannelState(index: n + 1, name: name, faderDB: fader, muted: on == 0, eq: eq, auxSendsDB: sends))
        }
        var outputs: [OutputState] = []
        let mainEQ = (1...model.mainEQBands).map { EQBand(index: $0, frequencyHz: 1000, gainDB: 0, q: 1, enabled: false) }
        outputs.append(OutputState(target: .mainLR, name: "Stereo", faderDB: Self.levelToDB(try await get("St/Fader/Level", 0, 0)), muted: (try await get("St/Fader/On", 0, 0)) == 0, eq: mainEQ))
        for mix in 0..<min(model.auxCount, 16) {
            outputs.append(OutputState(target: .aux(mix + 1), name: "Mix \(mix + 1)", faderDB: Self.levelToDB((try? await get("Mix/Fader/Level", mix, 0)) ?? -32768), muted: ((try? await get("Mix/Fader/On", mix, 0)) ?? 1) == 0, eq: []))
        }
        return MixerState(model: model, firmwareVersion: firmware, channels: channels, outputs: outputs)
    }

    public func meters() async -> AsyncStream<Levels>? { nil }

    public func setFader(_ target: EQTarget, dB: Double) async throws {
        switch target {
        case .channel(let n): try await set("InCh/Fader/Level", n - 1, 0, Self.dbToLevel(dB))
        case .aux(let n): try await set("Mix/Fader/Level", n - 1, 0, Self.dbToLevel(dB))
        case .mainLR: try await set("St/Fader/Level", 0, 0, Self.dbToLevel(dB))
        default: throw MixerError.invalidTarget(target)
        }
    }
    public func setMute(_ target: EQTarget, on: Bool) async throws {
        switch target {
        case .channel(let n): try await set("InCh/Fader/On", n - 1, 0, on ? 0 : 1)
        case .aux(let n): try await set("Mix/Fader/On", n - 1, 0, on ? 0 : 1)
        case .mainLR: try await set("St/Fader/On", 0, 0, on ? 0 : 1)
        default: throw MixerError.invalidTarget(target)
        }
    }
    public func setPreampGain(channel: Int, dB: Double) async throws { try await set("InCh/Head Amp/Gain", channel - 1, 0, Int(dB * 100)) }
    public func setPan(channel: Int, pan: Double) async throws { try await set("InCh/ToSt/Pan", channel - 1, 0, Int(pan * 63)) }
    public func setEQBand(_ target: EQTarget, band: Int, frequencyHz: Double, gainDB: Double, q: Double, on: Bool) async throws {
        guard case .channel(let n) = target else { throw MixerError.protocolUnverified("Yamaha 출력 EQ 주소 미확인") }
        try await set("InCh/EQ/Band\(band)/F", n - 1, 0, Int(frequencyHz))
        try await set("InCh/EQ/Band\(band)/G", n - 1, 0, Int(gainDB * 100))
        try await set("InCh/EQ/Band\(band)/Q", n - 1, 0, Int(q * 100))
    }
    public func setEQEnabled(_ target: EQTarget, on: Bool) async throws {
        guard case .channel(let n) = target else { throw MixerError.protocolUnverified("Yamaha 출력 EQ 주소 미확인") }
        try await set("InCh/EQ/On", n - 1, 0, on ? 1 : 0)
    }
    public func setAuxSend(channel: Int, aux: Int, dB: Double) async throws { try await set("InCh/ToMix/Level", channel - 1, aux - 1, Self.dbToLevel(dB)) }
    public func setDelay(output: EQTarget, ms: Double) async throws { throw MixerError.protocolUnverified("Yamaha 출력 딜레이 주소 미확인") }
    public func setPhantom(channel: Int, on: Bool) async throws { try await set("InCh/Head Amp/Phantom", channel - 1, 0, on ? 1 : 0) }
    public func saveScene(number: Int, name: String) async throws { guard _status == .connected else { throw MixerError.notConnected }; _ = try await command("ssstore_ex scene_a \(number) \"\(name)\"") }
    public func recallScene(number: Int) async throws { guard _status == .connected else { throw MixerError.notConnected }; _ = try await command("ssrecall_ex scene_a \(number)") }
}
