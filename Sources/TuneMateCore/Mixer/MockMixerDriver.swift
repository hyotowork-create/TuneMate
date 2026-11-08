import Foundation

/// 하드웨어 없이 전체 흐름을 돌려 보는 시뮬레이터. 상태를 메모리에 두고 변경을 즉시 반영한다.
public actor MockMixerDriver: MixerDriver {
    public nonisolated let model: MixerModel
    private var state: MixerState
    private var _status: ConnectionStatus = .disconnected
    private var savedScenes: [Int: MixerState] = [:]
    public var simulatedLatencyMs: Double = 0
    public private(set) var writeLog: [String] = []

    public init(model: MixerModel = .mock, channelNames: [Int: String] = [:]) {
        self.model = model
        self.state = Self.defaultState(model: model, channelNames: channelNames)
    }

    public static func defaultState(model: MixerModel, channelNames: [Int: String] = [:]) -> MixerState {
        let defaultFreqs = [100.0, 400, 1_600, 6_300, 10_000, 12_000, 14_000, 16_000]
        func bands(_ n: Int) -> [EQBand] {
            (1...max(1, n)).map { EQBand(index: $0, frequencyHz: defaultFreqs[($0 - 1) % defaultFreqs.count], gainDB: 0, q: 1.0, enabled: false) }
        }
        let channels = (1...model.channelCount).map {
            ChannelState(index: $0, name: channelNames[$0] ?? "", faderDB: $0 <= 8 ? -10 : -90, muted: $0 > 8,
                         eq: bands(model.channelEQBands), auxSendsDB: [Double](repeating: -90, count: model.auxCount))
        }
        var outputs = [OutputState(target: .mainLR, name: "Main L/R", faderDB: -3, eq: bands(model.mainEQBands), delayMs: model.hasOutputDelay ? 0 : nil)]
        for a in 1...max(1, model.auxCount) {
            outputs.append(OutputState(target: .aux(a), name: "Aux \(a)", faderDB: -6, eq: bands(model.channelEQBands), delayMs: model.hasOutputDelay ? 0 : nil))
        }
        return MixerState(model: model, firmwareVersion: "sim-1.0", channels: channels, outputs: outputs,
                          scenes: [SceneInfo(number: 1, name: "주일예배"), SceneInfo(number: 2, name: "측정용 평탄")], currentScene: 1)
    }

    public var status: ConnectionStatus { _status }

    public func connect(host: String) async throws { _status = .connected }
    public func disconnect() async { _status = .disconnected }

    private func requireConnected() throws { guard _status == .connected else { throw MixerError.notConnected } }

    public func snapshot() async throws -> MixerState { try requireConnected(); var s = state; s.capturedAt = Date(); return s }

    public func meters() async -> AsyncStream<Levels>? {
        let snapshot = state
        return AsyncStream { continuation in
            let task = Task {
                var rng = SplitMix64(seed: 42)
                while !Task.isCancelled {
                    let ch = snapshot.channels.map { c -> Double in
                        c.muted || c.faderDB <= -80 ? -90 : -30 + c.faderDB * 0.5 + (rng.nextUniform() * 10 - 5)
                    }
                    continuation.yield(Levels(channelsDB: ch, outputsDB: [.mainLR: -12 + rng.nextUniform() * 6]))
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func log(_ s: String) { writeLog.append(s) }

    private func mutateChannel(_ n: Int, _ f: (inout ChannelState) -> Void) throws {
        guard let i = state.channels.firstIndex(where: { $0.index == n }) else { throw MixerError.invalidTarget(.channel(n)) }
        f(&state.channels[i])
    }
    private func mutateOutput(_ t: EQTarget, _ f: (inout OutputState) -> Void) throws {
        guard let i = state.outputs.firstIndex(where: { $0.target == t }) else { throw MixerError.invalidTarget(t) }
        f(&state.outputs[i])
    }

    public func setFader(_ target: EQTarget, dB: Double) async throws {
        try requireConnected()
        let v = min(model.faderRangeDB.upperBound, max(model.faderRangeDB.lowerBound, dB))
        if case .channel(let n) = target { try mutateChannel(n) { $0.faderDB = v } } else { try mutateOutput(target) { $0.faderDB = v } }
        log("fader \(target) \(v)")
    }
    public func setMute(_ target: EQTarget, on: Bool) async throws {
        try requireConnected()
        if case .channel(let n) = target { try mutateChannel(n) { $0.muted = on } } else { try mutateOutput(target) { $0.muted = on } }
        log("mute \(target) \(on)")
    }
    public func setPreampGain(channel: Int, dB: Double) async throws { try requireConnected(); try mutateChannel(channel) { $0.preampGainDB = dB }; log("gain CH\(channel) \(dB)") }
    public func setPan(channel: Int, pan: Double) async throws { try requireConnected(); try mutateChannel(channel) { $0.pan = max(-1, min(1, pan)) }; log("pan CH\(channel) \(pan)") }
    public func setEQBand(_ target: EQTarget, band: Int, frequencyHz: Double, gainDB: Double, q: Double, on: Bool) async throws {
        try requireConnected()
        let g = min(model.eqGainRangeDB.upperBound, max(model.eqGainRangeDB.lowerBound, gainDB))
        let qq = min(model.eqQRange.upperBound, max(model.eqQRange.lowerBound, q))
        func apply(_ eq: inout [EQBand]) throws {
            guard let i = eq.firstIndex(where: { $0.index == band }) else { throw MixerError.unsupported("band \(band)") }
            eq[i].frequencyHz = frequencyHz; eq[i].gainDB = g; eq[i].q = qq; eq[i].enabled = on
        }
        var err: Error?
        if case .channel(let n) = target { try mutateChannel(n) { do { try apply(&$0.eq) } catch { err = error } } }
        else { try mutateOutput(target) { do { try apply(&$0.eq) } catch { err = error } } }
        if let err { throw err }
        log("eq \(target) b\(band) \(frequencyHz)Hz \(g)dB Q\(qq) \(on)")
    }
    public func setEQEnabled(_ target: EQTarget, on: Bool) async throws {
        try requireConnected()
        if case .channel(let n) = target { try mutateChannel(n) { $0.eqOn = on } } else { try mutateOutput(target) { $0.eqOn = on } }
    }
    public func setAuxSend(channel: Int, aux: Int, dB: Double) async throws {
        try requireConnected()
        guard aux >= 1, aux <= model.auxCount else { throw MixerError.invalidTarget(.aux(aux)) }
        try mutateChannel(channel) { $0.auxSendsDB[aux - 1] = min(10, max(-90, dB)) }
        log("send CH\(channel)->AUX\(aux) \(dB)")
    }
    public func setDelay(output: EQTarget, ms: Double) async throws {
        try requireConnected()
        guard model.hasOutputDelay else { throw MixerError.unsupported("output delay") }
        try mutateOutput(output) { $0.delayMs = max(0, ms) }
    }
    public func setPhantom(channel: Int, on: Bool) async throws { try requireConnected(); try mutateChannel(channel) { $0.phantomOn = on }; log("phantom CH\(channel) \(on)") }
    public func saveScene(number: Int, name: String) async throws {
        try requireConnected()
        savedScenes[number] = state
        if let i = state.scenes.firstIndex(where: { $0.number == number }) { state.scenes[i].name = name } else { state.scenes.append(SceneInfo(number: number, name: name)) }
        state.scenes.sort { $0.number < $1.number }
        log("saveScene \(number) \(name)")
    }
    public func recallScene(number: Int) async throws {
        try requireConnected()
        guard let s = savedScenes[number] else { throw MixerError.unsupported("scene \(number) not saved in simulator") }
        let scenes = state.scenes
        state = s; state.scenes = scenes; state.currentScene = number
        log("recallScene \(number)")
    }

    /// 테스트용: 외부에서 상태를 바로 바꾼다 (예: 다른 사람이 공식 앱으로 조작한 상황).
    public func inject(_ f: @Sendable (inout MixerState) -> Void) { f(&state) }
}
