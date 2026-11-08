import Foundation

/// DM24.8 제어 드라이버 (DM24Kit). 명세(`ProtocolSpec`)가 `verified` 이고 펌웨어가 일치할 때만 쓴다.
/// 상태 읽기는 현재 명세에 "읽기 요청" 프레임이 정의되지 않아 로컬 캐시(마지막으로 쓴 값 + 수신 프레임 반영)로 유지한다.
public actor DM24Driver: MixerDriver {
    public nonisolated let model: MixerModel
    public let spec: ProtocolSpec
    private let codec: FrameCodec
    private let transport: any ByteTransport
    private var _status: ConnectionStatus = .disconnected
    private var cache: MixerState
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    /// 믹서가 보고한 펌웨어 (핸드셰이크 응답에서 읽을 수 있으면 채운다)
    public var reportedFirmware: String?

    public init(spec: ProtocolSpec, transport: any ByteTransport, model: MixerModel = .dm248) {
        var m = model
        m.protocolStatus = spec.status == .verified ? .reverseEngineered : .unverified
        self.model = m
        self.spec = spec
        self.codec = FrameCodec(spec: spec)
        self.transport = transport
        self.cache = MockMixerDriver.defaultState(model: m)
        self.cache.firmwareVersion = nil
    }

    public var status: ConnectionStatus { _status }

    public func connect(host: String) async throws {
        _status = .connecting
        do {
            try await transport.open(host: host, port: spec.port)
            if !spec.handshakeSend.isEmpty { try await transport.send(spec.handshakeSend) }
            _status = .connected
            startReceive()
            startKeepalive()
        } catch {
            _status = .failed("\(error)")
            throw error
        }
    }

    public func disconnect() async {
        receiveTask?.cancel(); keepaliveTask?.cancel()
        await transport.close()
        _status = .disconnected
    }

    private func startReceive() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.transport.incoming
            for await bytes in stream {
                await self.handleIncoming(bytes)
            }
        }
    }

    private func startKeepalive() {
        keepaliveTask?.cancel()
        guard spec.keepaliveIntervalMs > 0, !spec.keepaliveBytes.isEmpty else { return }
        let interval = UInt64(spec.keepaliveIntervalMs) * 1_000_000
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard let self else { return }
                try? await self.transport.send(self.spec.keepaliveBytes)
            }
        }
    }

    private func handleIncoming(_ bytes: [UInt8]) {
        guard let (addr, raw) = codec.decode(bytes) else { return }
        // 주소 → 파라미터 역매핑 (캐시 갱신)
        for p in spec.parameters.values {
            guard let e = spec.encodings[p.encoding] else { continue }
            let rel = addr - p.addressBase
            guard rel >= 0 else { continue }
            let idx = p.stride > 0 ? rel / p.stride : 0
            let rem = p.stride > 0 ? rel % p.stride : rel
            let band = p.bandStride > 0 ? rem / p.bandStride : 0
            let rem2 = p.bandStride > 0 ? rem % p.bandStride : rem
            guard rem2 == 0 else { continue }
            applyToCache(parameter: p.name, index: idx, band: band, value: e.decode(raw))
            return
        }
    }

    private func applyToCache(parameter: String, index: Int, band: Int, value: Double) {
        func ch(_ f: (inout ChannelState) -> Void) { if let i = cache.channels.firstIndex(where: { $0.index == index + 1 }) { f(&cache.channels[i]) } }
        func out(_ t: EQTarget, _ f: (inout OutputState) -> Void) { if let i = cache.outputs.firstIndex(where: { $0.target == t }) { f(&cache.outputs[i]) } }
        func eq(_ bands: inout [EQBand], _ f: (inout EQBand) -> Void) { if bands.indices.contains(band) { f(&bands[band]) } }
        switch parameter {
        case "channel.fader": ch { $0.faderDB = value }
        case "channel.mute": ch { $0.muted = value != 0 }
        case "channel.gain": ch { $0.preampGainDB = value }
        case "channel.pan": ch { $0.pan = value }
        case "channel.phantom": ch { $0.phantomOn = value != 0 }
        case "channel.eq.on": ch { $0.eqOn = value != 0 }
        case "channel.eq.freq": ch { c in eq(&c.eq) { $0.frequencyHz = value } }
        case "channel.eq.gain": ch { c in eq(&c.eq) { $0.gainDB = value } }
        case "channel.eq.q": ch { c in eq(&c.eq) { $0.q = value } }
        case "channel.eq.band_on": ch { c in eq(&c.eq) { $0.enabled = value != 0 } }
        case "channel.send": ch { if $0.auxSendsDB.indices.contains(band) { $0.auxSendsDB[band] = value } }
        case "aux.fader": out(.aux(index + 1)) { $0.faderDB = value }
        case "aux.mute": out(.aux(index + 1)) { $0.muted = value != 0 }
        case "aux.eq.freq": out(.aux(index + 1)) { o in eq(&o.eq) { $0.frequencyHz = value } }
        case "aux.eq.gain": out(.aux(index + 1)) { o in eq(&o.eq) { $0.gainDB = value } }
        case "aux.eq.q": out(.aux(index + 1)) { o in eq(&o.eq) { $0.q = value } }
        case "aux.eq.band_on": out(.aux(index + 1)) { o in eq(&o.eq) { $0.enabled = value != 0 } }
        case "main.fader": out(.mainLR) { $0.faderDB = value }
        case "main.mute": out(.mainLR) { $0.muted = value != 0 }
        case "main.eq.freq": out(.mainLR) { o in eq(&o.eq) { $0.frequencyHz = value } }
        case "main.eq.gain": out(.mainLR) { o in eq(&o.eq) { $0.gainDB = value } }
        case "main.eq.q": out(.mainLR) { o in eq(&o.eq) { $0.q = value } }
        case "main.eq.band_on": out(.mainLR) { o in eq(&o.eq) { $0.enabled = value != 0 } }
        case "scene.recall": cache.currentScene = Int(value)
        default: break
        }
    }

    // MARK: 쓰기 보호

    private func guardWrite(_ parameter: String) throws {
        guard _status == .connected else { throw MixerError.notConnected }
        guard spec.status == .verified else { throw MixerError.protocolUnverified("명세 status=\(spec.status.rawValue)") }
        if spec.firmware != "unknown", let fw = reportedFirmware, fw != spec.firmware {
            throw MixerError.firmwareMismatch(expected: spec.firmware, actual: fw)
        }
        guard let p = spec.parameters[parameter] else { throw MixerError.unsupported(parameter) }
        guard p.verified else { throw MixerError.protocolUnverified("파라미터 \(parameter) 미검증") }
    }

    private func write(_ parameter: String, index: Int = 0, band: Int = 0, value: Double) async throws {
        try guardWrite(parameter)
        let frame = try codec.encodeSet(parameter: parameter, index: index, band: band, value: value)
        try await transport.send(frame)
        applyToCache(parameter: parameter, index: index, band: band, value: value)
    }

    private func split(_ t: EQTarget) throws -> (prefix: String, index: Int) {
        switch t {
        case .channel(let n): return ("channel", n - 1)
        case .aux(let n): return ("aux", n - 1)
        case .mainLR: return ("main", 0)
        default: throw MixerError.invalidTarget(t)
        }
    }

    // MARK: MixerDriver

    public func snapshot() async throws -> MixerState {
        guard _status == .connected else { throw MixerError.notConnected }
        var s = cache; s.capturedAt = Date(); s.firmwareVersion = reportedFirmware
        return s
    }
    public func meters() async -> AsyncStream<Levels>? { nil } // Phase 0 "미터 스트림 확인" 뒤 구현

    public func setFader(_ target: EQTarget, dB: Double) async throws { let (p, i) = try split(target); try await write("\(p).fader", index: i, value: dB) }
    public func setMute(_ target: EQTarget, on: Bool) async throws { let (p, i) = try split(target); try await write("\(p).mute", index: i, value: on ? 1 : 0) }
    public func setPreampGain(channel: Int, dB: Double) async throws { try await write("channel.gain", index: channel - 1, value: dB) }
    public func setPan(channel: Int, pan: Double) async throws { try await write("channel.pan", index: channel - 1, value: pan) }
    public func setEQBand(_ target: EQTarget, band: Int, frequencyHz: Double, gainDB: Double, q: Double, on: Bool) async throws {
        let (p, i) = try split(target)
        try await write("\(p).eq.freq", index: i, band: band - 1, value: frequencyHz)
        try await write("\(p).eq.gain", index: i, band: band - 1, value: gainDB)
        try await write("\(p).eq.q", index: i, band: band - 1, value: q)
        try await write("\(p).eq.band_on", index: i, band: band - 1, value: on ? 1 : 0)
    }
    public func setEQEnabled(_ target: EQTarget, on: Bool) async throws { let (p, i) = try split(target); try await write("\(p).eq.on", index: i, value: on ? 1 : 0) }
    public func setAuxSend(channel: Int, aux: Int, dB: Double) async throws { try await write("channel.send", index: channel - 1, band: aux - 1, value: dB) }
    public func setDelay(output: EQTarget, ms: Double) async throws { throw MixerError.unsupported("output delay (확인 필요 항목)") }
    public func setPhantom(channel: Int, on: Bool) async throws { try await write("channel.phantom", index: channel - 1, value: on ? 1 : 0) }
    public func saveScene(number: Int, name: String) async throws { try await write("scene.save", value: Double(number)) }
    public func recallScene(number: Int) async throws { try await write("scene.recall", value: Double(number)) }
}
