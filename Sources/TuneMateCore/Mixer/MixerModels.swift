import Foundation

/// 조정 대상 (채널·버스·메인 등). 모든 믹서 드라이버가 공통으로 쓴다.
public enum EQTarget: Hashable, Codable, Sendable, CustomStringConvertible {
    case channel(Int)      // 1-based
    case aux(Int)          // 1-based (X32는 bus)
    case mainLR
    case dca(Int)
    case fxReturn(Int)

    public var description: String {
        switch self {
        case .channel(let n): return "CH\(n)"
        case .aux(let n): return "AUX\(n)"
        case .mainLR: return "MAIN"
        case .dca(let n): return "DCA\(n)"
        case .fxReturn(let n): return "FX\(n)"
        }
    }

    public init?(parsing s: String) {
        let u = s.uppercased().trimmingCharacters(in: .whitespaces)
        if u == "MAIN" || u == "MAIN L/R" || u == "LR" { self = .mainLR; return }
        func num(_ p: String) -> Int? { Int(u.dropFirst(p.count)) }
        if u.hasPrefix("CH"), let n = num("CH") { self = .channel(n); return }
        if u.hasPrefix("AUX"), let n = num("AUX") { self = .aux(n); return }
        if u.hasPrefix("BUS"), let n = num("BUS") { self = .aux(n); return }
        if u.hasPrefix("DCA"), let n = num("DCA") { self = .dca(n); return }
        if u.hasPrefix("FX"), let n = num("FX") { self = .fxReturn(n); return }
        if let n = Int(u) { self = .channel(n); return }
        return nil
    }
}

public struct EQBand: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int          // 1-based
    public var type: EQFilterType
    public var frequencyHz: Double
    public var gainDB: Double
    public var q: Double
    public var enabled: Bool

    public init(index: Int, type: EQFilterType = .peaking, frequencyHz: Double, gainDB: Double, q: Double, enabled: Bool) {
        self.index = index; self.type = type; self.frequencyHz = frequencyHz; self.gainDB = gainDB; self.q = q; self.enabled = enabled
    }

    public var filter: EQFilter { EQFilter(type: type, frequencyHz: frequencyHz, gainDB: gainDB, q: q, enabled: enabled) }
}

public struct ChannelState: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var name: String
    public var faderDB: Double
    public var muted: Bool
    public var preampGainDB: Double
    public var phantomOn: Bool
    public var pan: Double          // -1 ... 1
    public var eqOn: Bool
    public var eq: [EQBand]
    public var auxSendsDB: [Double] // index 0 = AUX1
    public var gateOn: Bool
    public var compressorOn: Bool

    public init(index: Int, name: String = "", faderDB: Double = -90, muted: Bool = false, preampGainDB: Double = 20,
                phantomOn: Bool = false, pan: Double = 0, eqOn: Bool = true, eq: [EQBand], auxSendsDB: [Double],
                gateOn: Bool = false, compressorOn: Bool = false) {
        self.index = index; self.name = name; self.faderDB = faderDB; self.muted = muted; self.preampGainDB = preampGainDB
        self.phantomOn = phantomOn; self.pan = pan; self.eqOn = eqOn; self.eq = eq; self.auxSendsDB = auxSendsDB
        self.gateOn = gateOn; self.compressorOn = compressorOn
    }
}

public struct OutputState: Codable, Equatable, Sendable, Identifiable {
    public var id: EQTarget { target }
    public var target: EQTarget
    public var name: String
    public var faderDB: Double
    public var muted: Bool
    public var eqOn: Bool
    public var eq: [EQBand]
    public var delayMs: Double?

    public init(target: EQTarget, name: String, faderDB: Double = 0, muted: Bool = false, eqOn: Bool = true, eq: [EQBand], delayMs: Double? = nil) {
        self.target = target; self.name = name; self.faderDB = faderDB; self.muted = muted; self.eqOn = eqOn; self.eq = eq; self.delayMs = delayMs
    }
}

public struct SceneInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { number }
    public var number: Int
    public var name: String
    public init(number: Int, name: String) { self.number = number; self.name = name }
}

/// 믹서 전체 상태 스냅샷.
public struct MixerState: Codable, Equatable, Sendable {
    public var model: MixerModel
    public var firmwareVersion: String?
    public var channels: [ChannelState]
    public var outputs: [OutputState]
    public var scenes: [SceneInfo]
    public var currentScene: Int?
    public var capturedAt: Date

    public init(model: MixerModel, firmwareVersion: String? = nil, channels: [ChannelState], outputs: [OutputState], scenes: [SceneInfo] = [], currentScene: Int? = nil, capturedAt: Date = Date()) {
        self.model = model; self.firmwareVersion = firmwareVersion; self.channels = channels; self.outputs = outputs
        self.scenes = scenes; self.currentScene = currentScene; self.capturedAt = capturedAt
    }

    public func channel(_ n: Int) -> ChannelState? { channels.first { $0.index == n } }
    public func output(_ t: EQTarget) -> OutputState? { outputs.first { $0.target == t } }
    public var main: OutputState? { output(.mainLR) }

    public func eq(of target: EQTarget) -> [EQBand]? {
        if case .channel(let n) = target { return channel(n)?.eq }
        return output(target)?.eq
    }
    public func faderDB(of target: EQTarget) -> Double? {
        if case .channel(let n) = target { return channel(n)?.faderDB }
        return output(target)?.faderDB
    }
    public func muted(_ target: EQTarget) -> Bool? {
        if case .channel(let n) = target { return channel(n)?.muted }
        return output(target)?.muted
    }

    /// AI 프롬프트용 짧은 요약
    public func summary() -> String {
        var s = "믹서: \(model.displayName)" + (firmwareVersion.map { " fw \($0)" } ?? "") + "\n"
        for c in channels {
            let eqDesc = c.eq.filter { $0.enabled && abs($0.gainDB) >= 0.05 }
                .map { String(format: "%.0fHz %+.1fdB Q%.1f", $0.frequencyHz, $0.gainDB, $0.q) }.joined(separator: ", ")
            s += String(format: "CH%d %@: fader %.1f dB%@, gain %.0f dB%@%@\n", c.index, c.name.isEmpty ? "-" : c.name, c.faderDB,
                        c.muted ? " MUTE" : "", c.preampGainDB, c.phantomOn ? " +48V" : "", eqDesc.isEmpty ? "" : ", EQ[\(eqDesc)]")
        }
        for o in outputs {
            let eqDesc = o.eq.filter { $0.enabled && abs($0.gainDB) >= 0.05 }
                .map { String(format: "%.0fHz %+.1fdB Q%.1f", $0.frequencyHz, $0.gainDB, $0.q) }.joined(separator: ", ")
            s += String(format: "%@ %@: fader %.1f dB%@%@\n", o.target.description, o.name, o.faderDB, o.muted ? " MUTE" : "", eqDesc.isEmpty ? "" : ", EQ[\(eqDesc)]")
        }
        return s
    }
}

/// 미터 한 프레임 (dBFS 또는 dBu — 드라이버가 명시).
public struct Levels: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var channelsDB: [Double]
    public var outputsDB: [EQTarget: Double]
    public init(timestamp: Date = Date(), channelsDB: [Double], outputsDB: [EQTarget: Double]) {
        self.timestamp = timestamp; self.channelsDB = channelsDB; self.outputsDB = outputsDB
    }
}

/// 지원 믹서 모델과 능력(capability) 표.
public struct MixerModel: Codable, Equatable, Hashable, Sendable {
    public enum Family: String, Codable, Sendable, CaseIterable {
        case toppProDM24    // SEIKAKU 2세대 (프로토콜 비공개 → 역분석)
        case behringerX32   // X32 / M32 (OSC 10023)
        case behringerXAir  // XR18/XR16/XR12/MR18/MR12 (OSC 10024)
        case yamahaDM       // DM7 / DM3 (OSC)
        case allenHeathSQ   // SQ (MIDI over TCP 51325) — 미구현
        case mock
    }
    public var family: Family
    public var name: String
    public var channelCount: Int
    public var auxCount: Int
    public var channelEQBands: Int
    public var mainEQBands: Int
    public var mainEQKind: String        // "PEQ" | "GEQ" | "PEQ+GEQ" | "unknown"
    public var hasOutputDelay: Bool
    public var faderRangeDB: ClosedRange<Double>
    public var eqGainRangeDB: ClosedRange<Double>
    public var eqQRange: ClosedRange<Double>
    public var protocolStatus: ProtocolStatus

    public enum ProtocolStatus: String, Codable, Sendable {
        case publicSpec      // 공개 사양 (OSC 등)
        case reverseEngineered
        case unverified      // 역분석 전/중 — 쓰기 금지
    }

    public var displayName: String { name }

    public init(family: Family, name: String, channelCount: Int, auxCount: Int, channelEQBands: Int, mainEQBands: Int, mainEQKind: String,
                hasOutputDelay: Bool, faderRangeDB: ClosedRange<Double> = -90...10, eqGainRangeDB: ClosedRange<Double> = -15...15,
                eqQRange: ClosedRange<Double> = 0.3...10, protocolStatus: ProtocolStatus) {
        self.family = family; self.name = name; self.channelCount = channelCount; self.auxCount = auxCount
        self.channelEQBands = channelEQBands; self.mainEQBands = mainEQBands; self.mainEQKind = mainEQKind
        self.hasOutputDelay = hasOutputDelay; self.faderRangeDB = faderRangeDB; self.eqGainRangeDB = eqGainRangeDB
        self.eqQRange = eqQRange; self.protocolStatus = protocolStatus
    }

    // 알려진 모델 (공개 사양 기준). 미확인 값은 기획서 12장 확인 항목으로 남긴다.
    public static let dm248 = MixerModel(family: .toppProDM24, name: "TOPP PRO DM24.8", channelCount: 24, auxCount: 8, channelEQBands: 4,
                                         mainEQBands: 4, mainEQKind: "unknown", hasOutputDelay: false, protocolStatus: .unverified)
    public static let x32 = MixerModel(family: .behringerX32, name: "Behringer X32 / Midas M32", channelCount: 32, auxCount: 16, channelEQBands: 4,
                                       mainEQBands: 6, mainEQKind: "PEQ", hasOutputDelay: true, protocolStatus: .publicSpec)
    public static let xr18 = MixerModel(family: .behringerXAir, name: "Behringer XR18 / Midas MR18", channelCount: 16, auxCount: 6, channelEQBands: 4,
                                        mainEQBands: 6, mainEQKind: "PEQ+GEQ", hasOutputDelay: false, protocolStatus: .publicSpec)
    public static let xr16 = MixerModel(family: .behringerXAir, name: "Behringer XR16", channelCount: 16, auxCount: 4, channelEQBands: 4,
                                        mainEQBands: 6, mainEQKind: "PEQ+GEQ", hasOutputDelay: false, protocolStatus: .publicSpec)
    public static let xr12 = MixerModel(family: .behringerXAir, name: "Behringer XR12 / Midas MR12", channelCount: 12, auxCount: 2, channelEQBands: 4,
                                        mainEQBands: 6, mainEQKind: "PEQ+GEQ", hasOutputDelay: false, protocolStatus: .publicSpec)
    public static let dm7 = MixerModel(family: .yamahaDM, name: "Yamaha DM7", channelCount: 120, auxCount: 48, channelEQBands: 4,
                                       mainEQBands: 8, mainEQKind: "PEQ", hasOutputDelay: true, protocolStatus: .publicSpec)
    public static let dm3 = MixerModel(family: .yamahaDM, name: "Yamaha DM3", channelCount: 22, auxCount: 6, channelEQBands: 4,
                                       mainEQBands: 8, mainEQKind: "PEQ", hasOutputDelay: true, protocolStatus: .publicSpec)
    public static let mock = MixerModel(family: .mock, name: "시뮬레이터 (DM24.8 구성)", channelCount: 24, auxCount: 8, channelEQBands: 4,
                                        mainEQBands: 4, mainEQKind: "PEQ", hasOutputDelay: false, protocolStatus: .publicSpec)

    public static let known: [MixerModel] = [dm248, x32, xr18, xr16, xr12, dm7, dm3, mock]
}
