import Foundation

/// 하울링 자동 억제 (리허설 자동 모드): 후보가 확정되면 노치 변경안을 만들어 넘긴다.
/// 같은 주파수는 쿨다운 동안 다시 처리하지 않고, 한 주파수당 깊이 한도는 NotchPlanner 가 지킨다.
public struct SuppressorOptions: Codable, Equatable, Sendable {
    public var minConfidence: Double = 0.7
    public var cooldownSeconds: Double = 5
    public var sameFrequencyToleranceOctaves: Double = 1.0 / 12
    public var maxNotchesPerSession: Int = 12
    public init() {}
}

public struct SuppressionEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var at: Date = Date()
    public var frequencyHz: Double
    public var target: EQTarget
    public var band: Int
    public var gainDB: Double
    public var outcome: String   // "적용", "승인 대기", "거절: …"
}

public final class FeedbackSuppressor {
    public var options: SuppressorOptions
    public private(set) var events: [SuppressionEvent] = []
    private var lastHandled: [(hz: Double, at: Date)] = []

    public init(options: SuppressorOptions = SuppressorOptions()) { self.options = options }

    public func reset() { events.removeAll(); lastHandled.removeAll() }

    /// 후보 목록에서 지금 처리할 후보 하나를 고른다 (신뢰도 최고, 쿨다운 밖).
    public func pick(from candidates: [FeedbackCandidate], now: Date = Date()) -> FeedbackCandidate? {
        guard events.count < options.maxNotchesPerSession else { return nil }
        lastHandled.removeAll { now.timeIntervalSince($0.at) > options.cooldownSeconds }
        return candidates
            .filter { $0.confidence >= options.minConfidence }
            .filter { c in !lastHandled.contains { abs(log2($0.hz / c.frequencyHz)) <= options.sameFrequencyToleranceOctaves } }
            .max { $0.confidence < $1.confidence }
    }

    /// 후보 → 변경안. 적용 결과는 record(_:) 로 기록한다.
    public func proposal(for c: FeedbackCandidate, channel: Int?, state: MixerState, policy: NotchPolicy, now: Date = Date()) -> (ChangeProposal, EQTarget, Int, Double)? {
        let chEQ = channel.flatMap { state.channel($0)?.eq }
        let plan = NotchPlanner.plan(frequencyHz: c.frequencyHz, channel: channel.map { .channel($0) }, channelEQ: chEQ, mainEQ: state.main?.eq ?? [], policy: policy)
        lastHandled.append((c.frequencyHz, now))
        switch plan {
        case .newBand(let t, let b, let f):
            return (ChangeProposal(source: .feedbackSuppressor, rationale: String(format: "하울링 %.0f Hz 자동 억제", c.frequencyHz),
                                   changes: [.eqBand(target: t, band: b, frequencyHz: f.frequencyHz, gainDB: f.gainDB, q: f.q, on: true)]), t, b, f.gainDB)
        case .deepenBand(let t, let b, let g):
            let cur = state.eq(of: t)?.first { $0.index == b }
            return (ChangeProposal(source: .feedbackSuppressor, rationale: String(format: "하울링 %.0f Hz 노치 깊게", c.frequencyHz),
                                   changes: [.eqBand(target: t, band: b, frequencyHz: cur?.frequencyHz ?? c.frequencyHz, gainDB: g, q: cur?.q ?? policy.q, on: true)]), t, b, g)
        case .noBandAvailable(let advice), .depthLimitReached(_, _, let advice):
            events.append(SuppressionEvent(frequencyHz: c.frequencyHz, target: .mainLR, band: 0, gainDB: 0, outcome: "불가: " + advice))
            return nil
        }
    }

    public func record(frequencyHz: Double, target: EQTarget, band: Int, gainDB: Double, outcome: String) {
        events.append(SuppressionEvent(frequencyHz: frequencyHz, target: target, band: band, gainDB: gainDB, outcome: outcome))
    }
}

/// 링아웃 도우미: 게인을 올리며 먼저 우는 주파수를 순서대로 기록하고, 한 번에 노치 변경안을 만든다.
public struct RingOutSession: Codable, Equatable, Sendable {
    public struct Hit: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID = UUID()
        public var at: Date = Date()
        public var frequencyHz: Double
        public var prominenceDB: Double
    }
    public var startedAt: Date = Date()
    public var channel: Int?
    public var hits: [Hit] = []
    public var toleranceOctaves: Double = 1.0 / 12

    public init(channel: Int? = nil) { self.channel = channel }

    /// 새 후보를 기록 (이미 있는 주파수면 돌출만 갱신)
    public mutating func register(_ c: FeedbackCandidate) {
        if let i = hits.firstIndex(where: { abs(log2($0.frequencyHz / c.frequencyHz)) <= toleranceOctaves }) {
            if c.prominenceDB > hits[i].prominenceDB { hits[i].prominenceDB = c.prominenceDB; hits[i].frequencyHz = c.frequencyHz }
        } else {
            hits.append(Hit(frequencyHz: c.frequencyHz, prominenceDB: c.prominenceDB))
        }
    }

    /// 기록된 주파수 전부에 노치를 거는 변경안 (빈 밴드가 모자라면 앞에서부터, 나머지는 메모에)
    public func proposal(state: MixerState, policy: NotchPolicy) -> (ChangeProposal?, [String]) {
        var working = state
        var changes: [MixerChange] = []
        var notes: [String] = []
        for h in hits.sorted(by: { $0.prominenceDB > $1.prominenceDB }) {
            let chEQ = channel.flatMap { working.channel($0)?.eq }
            let plan = NotchPlanner.plan(frequencyHz: h.frequencyHz, channel: channel.map { .channel($0) }, channelEQ: chEQ, mainEQ: working.main?.eq ?? [], policy: policy)
            switch plan {
            case .newBand(let t, let b, let f):
                changes.append(.eqBand(target: t, band: b, frequencyHz: f.frequencyHz, gainDB: f.gainDB, q: f.q, on: true))
                // 같은 밴드를 다시 쓰지 않도록 작업 상태에 반영
                if case .channel(let n) = t, let ci = working.channels.firstIndex(where: { $0.index == n }), let bi = working.channels[ci].eq.firstIndex(where: { $0.index == b }) {
                    working.channels[ci].eq[bi] = EQBand(index: b, frequencyHz: f.frequencyHz, gainDB: f.gainDB, q: f.q, enabled: true)
                } else if let oi = working.outputs.firstIndex(where: { $0.target == t }), let bi = working.outputs[oi].eq.firstIndex(where: { $0.index == b }) {
                    working.outputs[oi].eq[bi] = EQBand(index: b, frequencyHz: f.frequencyHz, gainDB: f.gainDB, q: f.q, enabled: true)
                }
            case .deepenBand(let t, let b, let g):
                let cur = working.eq(of: t)?.first { $0.index == b }
                changes.append(.eqBand(target: t, band: b, frequencyHz: cur?.frequencyHz ?? h.frequencyHz, gainDB: g, q: cur?.q ?? policy.q, on: true))
            case .noBandAvailable, .depthLimitReached:
                notes.append(String(format: "%.0f Hz: 빈 밴드 없음 — 게인을 낮추거나 마이크·스피커 위치 조정", h.frequencyHz))
            }
        }
        guard !changes.isEmpty else { return (nil, notes) }
        return (ChangeProposal(source: .feedbackSuppressor, rationale: "링아웃: 하울링 주파수 \(changes.count)곳 선제 노치", changes: changes), notes)
    }
}
