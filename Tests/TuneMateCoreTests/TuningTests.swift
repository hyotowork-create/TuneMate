import Testing
import Foundation
@testable import TuneMateCore

@Suite("Tuning")
struct TuningTests {
    @Test func peakingFilterGainAtCenter() {
        let f = EQFilter(frequencyHz: 1000, gainDB: -6, q: 2)
        #expect(abs(f.magnitudeDB(at: 1000) - (-6)) < 1e-6)
        #expect(abs(f.magnitudeDB(at: 100)) < 0.2)
        #expect(abs(f.magnitudeDB(at: 10_000)) < 0.2)
    }

    @Test func autoEQCutsPeakAndRespectsBoostLimit() {
        let grid = FrequencyResponse.logGrid(pointsPerOctave: 48)
        // 평탄 + 250 Hz 에 +8 dB 피크(Q 2) + 4 kHz에 −6 dB 딥(Q 1.5) + 60 Hz 깊은 딥 −15
        let peak = EQFilter(frequencyHz: 250, gainDB: 8, q: 2)
        let dip = EQFilter(frequencyHz: 4000, gainDB: -6, q: 1.5)
        let deep = EQFilter(frequencyHz: 60, gainDB: -15, q: 4)
        let room = FrequencyResponse(frequencies: grid, magnitudesDB: grid.map { peak.magnitudeDB(at: $0) + dip.magnitudeDB(at: $0) + deep.magnitudeDB(at: $0) + 70 })
        var opt = AutoEQOptions()
        opt.maxFilters = 4
        let r = AutoEQ.compute(response: room, target: .flat, options: opt)
        #expect(r.filters.count <= 4)
        #expect(r.filters.count >= 1)
        // 250 Hz 근처에 컷 필터가 있다
        let cut = r.filters.first { abs(log2($0.frequencyHz / 250)) < 0.25 }
        #expect(cut != nil)
        #expect((cut?.gainDB ?? 0) < -5)
        // 부스트는 한도 이내
        #expect(r.filters.allSatisfy { $0.gainDB <= opt.maxBoostDB + 1e-9 })
        // 깊은 딥은 제외됐다
        #expect(!r.excludedDips.isEmpty)
        #expect(r.residualRMSDB < r.initialRMSDB)
        // 예상 응답은 250 Hz 에서 목표 ±2 dB
        #expect(abs(r.predicted.magnitudeDB(at: 250) - r.target.magnitudeDB(at: 250)) < 2)
    }

    @Test func autoEQLeavesFlatAlone() {
        let grid = FrequencyResponse.logGrid(pointsPerOctave: 48)
        let flat = FrequencyResponse(frequencies: grid, magnitudesDB: grid.map { _ in 65 })
        let r = AutoEQ.compute(response: flat, target: .flat)
        #expect(r.filters.isEmpty)
    }

    @Test func assignmentTable() {
        let rows = [EQAssignment(target: "Main L/R", band: 1, frequencyHz: 250, gainDB: -6.5, q: 2.0)]
        let md = EQAssignment.markdownTable(rows)
        #expect(md.contains("| Main L/R | 1 | 250 | -6.5 | 2.0 |"))
    }

    @Test func feedbackDetectorCatchesGrowingToneIgnoresBurst() {
        let sr = 48_000.0
        let rta = RealTimeAnalyzer(sampleRate: sr, fftSize: 8192, averaging: 0)
        let det = FeedbackDetector()
        var rng = SplitMix64(seed: 7)
        func frame(toneDB: Double?, f0: Double = 3_150) -> SpectrumFrame {
            let amp = toneDB.map { Decibel.toAmplitude($0) } ?? 0
            let block = (0..<8192).map { i in
                0.01 * (rng.nextUniform() * 2 - 1) + amp * sin(2 * Double.pi * f0 * Double(i) / sr)
            }
            return rta.analyze(block)
        }
        // 노이즈만: 후보 없음
        for _ in 0..<5 { #expect(det.process(frame(toneDB: nil)).isEmpty) }
        // 한 프레임 버스트: 후보 없음
        #expect(det.process(frame(toneDB: -10)).isEmpty)
        for _ in 0..<3 { #expect(det.process(frame(toneDB: nil)).isEmpty) }
        // 커지는 톤 8프레임
        var result: [FeedbackCandidate] = []
        for k in 0..<8 { result = det.process(frame(toneDB: -30 + Double(k) * 2)) }
        #expect(result.count == 1)
        if let c = result.first {
            #expect(abs(c.frequencyHz - 3_150) < 15)
            #expect(c.growthDB >= 2)
            #expect(c.confidence > 0.5)
        }
    }

    @Test func notchPlannerPrefersChannelFreeBandThenMain() {
        let chEQ = [EQBand(index: 1, frequencyHz: 100, gainDB: -3, q: 2, enabled: true),
                    EQBand(index: 2, frequencyHz: 1000, gainDB: 0, q: 1, enabled: false),
                    EQBand(index: 3, frequencyHz: 3000, gainDB: 0, q: 1, enabled: false),
                    EQBand(index: 4, frequencyHz: 8000, gainDB: 0, q: 1, enabled: false)]
        let main = [EQBand(index: 1, frequencyHz: 200, gainDB: 0, q: 1, enabled: false)]
        let p = NotchPlanner.plan(frequencyHz: 2_480, channel: .channel(1), channelEQ: chEQ, mainEQ: main)
        guard case .newBand(let target, let band, let filter) = p else { Issue.record("expected newBand"); return }
        #expect(target == .channel(1)); #expect(band == 2); #expect(filter.gainDB == -3); #expect(filter.q == 10)

        // 기존 노치 근처 → 깊게
        let chEQ2 = [EQBand(index: 1, frequencyHz: 2_500, gainDB: -3, q: 10, enabled: true)]
        let p2 = NotchPlanner.plan(frequencyHz: 2_480, channel: .channel(1), channelEQ: chEQ2, mainEQ: main)
        guard case .deepenBand(_, let b2, let g2) = p2 else { Issue.record("expected deepen"); return }
        #expect(b2 == 1); #expect(g2 == -6)

        // 한도
        let chEQ3 = [EQBand(index: 1, frequencyHz: 2_500, gainDB: -12, q: 10, enabled: true)]
        let p3 = NotchPlanner.plan(frequencyHz: 2_480, channel: .channel(1), channelEQ: chEQ3, mainEQ: [])
        guard case .depthLimitReached = p3 else { Issue.record("expected limit"); return }
    }
}
