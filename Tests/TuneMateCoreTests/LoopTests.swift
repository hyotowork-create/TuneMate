import Testing
import Foundation
@testable import TuneMateCore

@Suite("Tuning loop & suppressor")
struct LoopTests {
    @Test func verifyConvergesWhenVerifiedMatchesPrediction() {
        let grid = FrequencyResponse.logGrid()
        let flat = FrequencyResponse(frequencies: grid, magnitudesDB: grid.map { _ in 70 })
        var it = TuningIteration(index: 1, filters: [], predictedRMSDB: 0.5)
        let v = TuningLoop.verify(iteration: &it, verified: flat, target: .flat, predicted: FrequencyResponse(frequencies: grid, magnitudesDB: grid.map { _ in 0 }), autoEQ: AutoEQOptions(), previous: nil, options: TuningLoopOptions())
        guard case .converged(let r) = v else { Issue.record("expected converged, got \(v)"); return }
        #expect(r < 0.1); #expect(it.verifiedRMSDB != nil)
    }

    @Test func verifyFlagsPredictionMismatchAndStall() {
        let grid = FrequencyResponse.logGrid()
        let peak = EQFilter(frequencyHz: 250, gainDB: 12, q: 2)
        let room = FrequencyResponse(frequencies: grid, magnitudesDB: grid.map { 70 + peak.magnitudeDB(at: $0) })
        let predictedFlat = FrequencyResponse(frequencies: grid, magnitudesDB: grid.map { _ in 0 })
        var it = TuningIteration(index: 1, filters: [], predictedRMSDB: 0.3)
        // 예상은 평탄인데 실측은 피크 그대로 → EQ 미반영 판정
        let v = TuningLoop.verify(iteration: &it, verified: room, target: .flat, predicted: predictedFlat, autoEQ: AutoEQOptions(), previous: nil, options: TuningLoopOptions())
        guard case .stalled(_, let reason) = v else { Issue.record("expected stalled, got \(v)"); return }
        #expect(reason.contains("예상과 실측"))
        // 예상도 피크를 포함(모델 일치)하고 이전 회차와 차이가 없으면 정체
        let predictedPeak = FrequencyResponse(frequencies: grid, magnitudesDB: grid.map { peak.magnitudeDB(at: $0) })
        var prev = TuningIteration(index: 1, filters: [], predictedRMSDB: 2); prev.verifiedRMSDB = 2.0
        var it2 = TuningIteration(index: 2, filters: [], predictedRMSDB: 2)
        let v2 = TuningLoop.verify(iteration: &it2, verified: room, target: .flat, predicted: predictedPeak, autoEQ: AutoEQOptions(), previous: prev, options: TuningLoopOptions())
        guard case .stalled(_, let r2) = v2 else { Issue.record("expected stalled, got \(v2)"); return }
        #expect(r2.contains("개선이 작습니다"))
        // 개선 중
        var prev3 = TuningIteration(index: 1, filters: [], predictedRMSDB: 5); prev3.verifiedRMSDB = 5.0
        var it3 = TuningIteration(index: 2, filters: [], predictedRMSDB: 2)
        let v3 = TuningLoop.verify(iteration: &it3, verified: room, target: .flat, predicted: predictedPeak, autoEQ: AutoEQOptions(), previous: prev3, options: TuningLoopOptions())
        #expect(v3.shouldContinue)
        var it4 = TuningIteration(index: 3, filters: [], predictedRMSDB: 2)
        let v4 = TuningLoop.verify(iteration: &it4, verified: room, target: .flat, predicted: predictedPeak, autoEQ: AutoEQOptions(), previous: prev3, options: TuningLoopOptions())
        guard case .limitReached = v4 else { Issue.record("expected limit, got \(v4)"); return }
    }

    @Test func suppressorPicksWithCooldownAndLimits() {
        let sup = FeedbackSuppressor()
        let now = Date()
        let a = FeedbackCandidate(frequencyHz: 2480, levelDB: -20, prominenceDB: 20, persistenceFrames: 8, growthDB: 5, confidence: 0.9, firstSeen: now, lastSeen: now)
        let b = FeedbackCandidate(frequencyHz: 1200, levelDB: -30, prominenceDB: 14, persistenceFrames: 6, growthDB: 2, confidence: 0.5, firstSeen: now, lastSeen: now)
        #expect(sup.pick(from: [a, b], now: now)?.frequencyHz == 2480)
        let state = MockMixerDriver.defaultState(model: .mock)
        let p = sup.proposal(for: a, channel: 1, state: state, policy: NotchPolicy(), now: now)
        #expect(p != nil)
        if let (prop, t, band, g) = p { #expect(t == .channel(1)); #expect(band == 1); #expect(g == -3); #expect(prop.changes.count == 1) }
        // 쿨다운 중엔 같은 주파수 다시 안 고름
        #expect(sup.pick(from: [a], now: now.addingTimeInterval(2)) == nil)
        #expect(sup.pick(from: [a], now: now.addingTimeInterval(6))?.frequencyHz == 2480)
    }

    @Test func ringOutBuildsBatchProposalWithoutReusingBands() {
        var ring = RingOutSession(channel: 1)
        let now = Date()
        for (f, p) in [(2480.0, 18.0), (3150.0, 15.0), (2490.0, 20.0), (800.0, 13.0), (5000.0, 12.0), (6300.0, 12.0)] {
            ring.register(FeedbackCandidate(frequencyHz: f, levelDB: -20, prominenceDB: p, persistenceFrames: 6, growthDB: 3, confidence: 0.8, firstSeen: now, lastSeen: now))
        }
        #expect(ring.hits.count == 5) // 2480·2490 은 하나로 합침
        let state = MockMixerDriver.defaultState(model: .mock) // CH1 4밴드 + 메인 4밴드 = 8밴드 여유
        let (prop, notes) = ring.proposal(state: state, policy: NotchPolicy())
        #expect(prop?.changes.count == 5); #expect(notes.isEmpty)
        var bands: [String] = []
        for c in prop?.changes ?? [] { if case .eqBand(let t, let b, _, _, _, _) = c { bands.append("\(t)-\(b)") } }
        #expect(Set(bands).count == 5) // 같은 밴드를 두 번 쓰지 않음
        // 가장 돌출이 큰 2490 이 CH1 밴드 1
        if case .eqBand(let t, let b, let f, _, _, _) = prop!.changes[0] { #expect(t == .channel(1)); #expect(b == 1); #expect(abs(f - 2490) < 1) }
    }

    @Test func reportMarkdownContainsSections() {
        var s = MeasurementSession(venueName: "본당", microphone: .simulated, target: .speech)
        let grid = FrequencyResponse.logGrid()
        s.positions.append(PositionMeasurement(name: "A", response: FrequencyResponse(frequencies: grid, magnitudesDB: grid.map { 70 + EQFilter(frequencyHz: 100, gainDB: 6, q: 2).magnitudeDB(at: $0) }), irPeakTimeMs: 21.3, microphone: .simulated))
        s.recompute()
        let md = MeasurementReport.markdown(s, venue: VenueProfile(), mixer: .mock)
        #expect(md.contains("# 공간 측정 리포트 — 본당"))
        #expect(md.contains("| A | ")); #expect(md.contains("## 보정값")); #expect(md.contains("| Main L/R | 1 |"))
        #expect(md.contains("설교 중심"))
    }
}

@Suite("Peer messages")
struct PeerMessageTests {
    @Test func roundTripAllCases() throws {
        let state = MockMixerDriver.defaultState(model: .mock)
        let p = ChangeProposal(source: .ai, rationale: "t", changes: [.faderRelative(target: .channel(1), deltaDB: 2), .eqBand(target: .mainLR, band: 1, frequencyHz: 250, gainDB: -6, q: 2, on: true)])
        var session = MeasurementSession(venueName: "본당", microphone: .simulated)
        session.positions.append(PositionMeasurement(name: "A", response: FrequencyResponse(frequencies: [100, 1000], magnitudesDB: [70, 70]), microphone: .simulated))
        let msgs: [PeerMessage] = [
            .hello(deviceName: "iPad", role: "console"),
            .instruction(Instruction.from(proposal: p, state: state, sender: "Mac")),
            .acknowledged(id: UUID(), by: "iPad"),
            .proposal(requestID: UUID(), proposal: p),
            .outcome(RemoteOutcome(requestID: UUID(), kind: .applied, summaries: ["CH1 페이더"], reasons: [], by: "iPad")),
            .console(ConsoleStatus(deviceName: "iPad", connected: true, model: .dm248, mode: .rehearsalAuto, state: state, acceptsRemoteProposals: true)),
            .measurement(session),
            .venue(VenueProfile()),
            .feedback([FeedbackCandidate(frequencyHz: 2480, levelDB: -20, prominenceDB: 15, persistenceFrames: 6, growthDB: 3, confidence: 0.8, firstSeen: Date(), lastSeen: Date())], from: "iPhone")
        ]
        for m in msgs {
            let data = try JSONEncoder().encode(m)
            let back = try JSONDecoder().decode(PeerMessage.self, from: data)
            #expect(back == m)
        }
        let ins = Instruction.from(proposal: p, state: state, sender: "Mac")
        #expect(ins.steps.count == 2)
        #expect(ins.steps[0].text.contains("CH1 페이더 -10.0 dB → -8.0 dB"))
        #expect(ins.spokenText.contains("데시벨"))
    }
}
