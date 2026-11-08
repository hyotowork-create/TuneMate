import Foundation

/// 믹서 변경 한 건. AI는 절대값이 아닌 상대값(±dB)만 넘기고, 현재값 읽기·계산·쓰기는 앱이 한다.
public enum MixerChange: Codable, Equatable, Sendable {
    case faderRelative(target: EQTarget, deltaDB: Double)
    case faderAbsolute(target: EQTarget, dB: Double)
    case mute(target: EQTarget, on: Bool)
    case eqBand(target: EQTarget, band: Int, frequencyHz: Double, gainDB: Double, q: Double, on: Bool)
    case eqEnabled(target: EQTarget, on: Bool)
    case auxSendRelative(channel: Int, aux: Int, deltaDB: Double)
    case auxSendAbsolute(channel: Int, aux: Int, dB: Double)
    case preampGain(channel: Int, dB: Double)
    case pan(channel: Int, pan: Double)
    case delay(output: EQTarget, ms: Double)
    case phantom(channel: Int, on: Bool)
    case sceneRecall(number: Int)
    case routing(description: String)

    /// 항상 사람 확인이 필요한 종류 (팬텀·씬·라우팅)
    public var alwaysRequiresConfirmation: Bool {
        switch self {
        case .phantom, .sceneRecall, .routing: return true
        default: return false
        }
    }

    public var target: EQTarget? {
        switch self {
        case .faderRelative(let t, _), .faderAbsolute(let t, _), .mute(let t, _), .eqBand(let t, _, _, _, _, _), .eqEnabled(let t, _), .delay(let t, _): return t
        case .auxSendRelative(let c, _, _), .auxSendAbsolute(let c, _, _), .preampGain(let c, _), .pan(let c, _), .phantom(let c, _): return .channel(c)
        case .sceneRecall, .routing: return nil
        }
    }
}

/// 현재값 → 제안값으로 풀어 쓴 변경 (화면·로그 표시용).
public struct ResolvedChange: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var change: MixerChange
    public var summary: String       // "CH1 페이더 −10.0 → −7.0 dB"
    public var currentValue: String
    public var proposedValue: String
    /// 적용 시 실제로 쓸 절대값 변경
    public var absolute: MixerChange

    public init(change: MixerChange, summary: String, currentValue: String, proposedValue: String, absolute: MixerChange) {
        self.change = change; self.summary = summary; self.currentValue = currentValue; self.proposedValue = proposedValue; self.absolute = absolute
    }
}

public enum ProposalSource: String, Codable, Sendable { case ai, autoEQ, feedbackSuppressor, user, restore }

public struct ChangeProposal: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var source: ProposalSource
    public var rationale: String
    public var changes: [MixerChange]
    public var resolved: [ResolvedChange]

    public init(id: UUID = UUID(), createdAt: Date = Date(), source: ProposalSource, rationale: String, changes: [MixerChange], resolved: [ResolvedChange] = []) {
        self.id = id; self.createdAt = createdAt; self.source = source; self.rationale = rationale; self.changes = changes; self.resolved = resolved
    }
}

public enum ChangeResolver {
    /// 상대값을 현재 상태 기준 절대값으로 바꾸고 표시용 문자열을 만든다.
    public static func resolve(_ changes: [MixerChange], against state: MixerState) -> [ResolvedChange] {
        changes.map { resolve($0, against: state) }
    }

    public static func resolve(_ c: MixerChange, against s: MixerState) -> ResolvedChange {
        func db(_ v: Double) -> String { String(format: "%.1f dB", v) }
        switch c {
        case .faderRelative(let t, let d):
            let cur = s.faderDB(of: t) ?? -90
            let new = min(10, max(-90, cur + d))
            return ResolvedChange(change: c, summary: "\(t) 페이더 \(db(cur)) → \(db(new))", currentValue: db(cur), proposedValue: db(new), absolute: .faderAbsolute(target: t, dB: new))
        case .faderAbsolute(let t, let v):
            let cur = s.faderDB(of: t) ?? -90
            return ResolvedChange(change: c, summary: "\(t) 페이더 \(db(cur)) → \(db(v))", currentValue: db(cur), proposedValue: db(v), absolute: c)
        case .mute(let t, let on):
            let cur = s.muted(t) ?? false
            return ResolvedChange(change: c, summary: "\(t) 뮤트 \(cur ? "켬" : "끔") → \(on ? "켬" : "끔")", currentValue: cur ? "켬" : "끔", proposedValue: on ? "켬" : "끔", absolute: c)
        case .eqBand(let t, let b, let f, let g, let q, let on):
            let cur = s.eq(of: t)?.first { $0.index == b }
            let curS = cur.map { String(format: "%.0f Hz %+.1f dB Q%.1f%@", $0.frequencyHz, $0.gainDB, $0.q, $0.enabled ? "" : " (꺼짐)") } ?? "-"
            let newS = String(format: "%.0f Hz %+.1f dB Q%.1f%@", f, g, q, on ? "" : " (꺼짐)")
            return ResolvedChange(change: c, summary: "\(t) EQ \(b)밴드 \(curS) → \(newS)", currentValue: curS, proposedValue: newS, absolute: c)
        case .eqEnabled(let t, let on):
            return ResolvedChange(change: c, summary: "\(t) EQ \(on ? "켬" : "끔")", currentValue: "-", proposedValue: on ? "켬" : "끔", absolute: c)
        case .auxSendRelative(let ch, let aux, let d):
            let cur = s.channel(ch)?.auxSendsDB[safe: aux - 1] ?? -90
            let new = min(10, max(-90, cur + d))
            return ResolvedChange(change: c, summary: "CH\(ch)→AUX\(aux) 센드 \(db(cur)) → \(db(new))", currentValue: db(cur), proposedValue: db(new), absolute: .auxSendAbsolute(channel: ch, aux: aux, dB: new))
        case .auxSendAbsolute(let ch, let aux, let v):
            let cur = s.channel(ch)?.auxSendsDB[safe: aux - 1] ?? -90
            return ResolvedChange(change: c, summary: "CH\(ch)→AUX\(aux) 센드 \(db(cur)) → \(db(v))", currentValue: db(cur), proposedValue: db(v), absolute: c)
        case .preampGain(let ch, let v):
            let cur = s.channel(ch)?.preampGainDB ?? 0
            return ResolvedChange(change: c, summary: "CH\(ch) 프리앰프 게인 \(db(cur)) → \(db(v))", currentValue: db(cur), proposedValue: db(v), absolute: c)
        case .pan(let ch, let p):
            let cur = s.channel(ch)?.pan ?? 0
            return ResolvedChange(change: c, summary: String(format: "CH%d 팬 %.2f → %.2f", ch, cur, p), currentValue: String(format: "%.2f", cur), proposedValue: String(format: "%.2f", p), absolute: c)
        case .delay(let o, let ms):
            let cur = s.output(o)?.delayMs ?? 0
            return ResolvedChange(change: c, summary: String(format: "%@ 딜레이 %.1f → %.1f ms", o.description, cur, ms), currentValue: String(format: "%.1f ms", cur), proposedValue: String(format: "%.1f ms", ms), absolute: c)
        case .phantom(let ch, let on):
            let cur = s.channel(ch)?.phantomOn ?? false
            return ResolvedChange(change: c, summary: "CH\(ch) 팬텀 +48V \(cur ? "켬" : "끔") → \(on ? "켬" : "끔")", currentValue: cur ? "켬" : "끔", proposedValue: on ? "켬" : "끔", absolute: c)
        case .sceneRecall(let n):
            let name = s.scenes.first { $0.number == n }?.name ?? ""
            return ResolvedChange(change: c, summary: "씬 \(n) \(name) 불러오기", currentValue: s.currentScene.map(String.init) ?? "-", proposedValue: "\(n)", absolute: c)
        case .routing(let d):
            return ResolvedChange(change: c, summary: "라우팅 변경: \(d)", currentValue: "-", proposedValue: d, absolute: c)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
