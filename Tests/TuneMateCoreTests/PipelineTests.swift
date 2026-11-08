import Testing
import Foundation
@testable import TuneMateCore

@Suite("End-to-end pipeline")
struct PipelineTests {
    /// 가상 방 → 스윕 녹음 → 디컨볼루션 → 5지점 평균 → 보정 EQ → 예상 응답이 목표에 더 가깝다.
    @Test func simulatedRoomMeasurementImprovesResponse() {
        let room = SimulatedRoom(seed: 3)
        let spec = SweepSpec(sampleRate: 48_000, durationSeconds: 3, leadInSeconds: 0, tailSeconds: 0.5)
        let ref = SweepGenerator.sweep(spec)
        var session = MeasurementSession(venueName: "테스트 본당", microphone: .simulated, sweep: spec, target: .flat)
        session.autoEQOptions.maxFilters = 6
        for p in 1...5 {
            let rec = room.simulateRecording(spec: spec, position: p)
            var opt = Deconvolution.Options(); opt.bandLimit = 15...20_000
            let ir = Deconvolution.impulseResponse(recorded: rec, reference: ref, sampleRate: spec.sampleRate, options: opt)
            let resp = FrequencyResponse.fromLinear(TransferFunction.magnitudeSpectrum(ir))
            session.positions.append(PositionMeasurement(name: "좌석 \(p)", response: resp, irPeakTimeMs: ir.peakTimeSeconds * 1000, microphone: .simulated))
            // 측정된 응답이 참 응답과 가깝다 (100 Hz~10 kHz, 1.5 dB 이내 — 위치별 무작위 ±0.3 포함)
            let truth = room.trueResponse(position: p)
            let smoothed = resp.smoothed(fractionOfOctave: 6)
            let offset = truth.meanDB(in: 200...2000) - smoothed.meanDB(in: 200...2000)
            var maxErr = 0.0
            for f in FrequencyResponse.logGrid(lowHz: 100, highHz: 10_000, pointsPerOctave: 6) { maxErr = max(maxErr, abs(smoothed.magnitudeDB(at: f) + offset - truth.smoothed(fractionOfOctave: 6).magnitudeDB(at: f))) }
            #expect(maxErr < 1.5, "position \(p) max error \(maxErr)")
        }
        session.recompute()
        let r = session.result!
        #expect(r.filters.count >= 3 && r.filters.count <= 6)
        #expect(r.residualRMSDB < r.initialRMSDB * 0.7, "rms \(r.initialRMSDB) → \(r.residualRMSDB)")
        // 180 Hz 깊은 딥은 제외 목록에 있다
        #expect(r.excludedDips.contains { $0.overlaps(150...210) })
        // 같은 주파수에 필터가 겹치지 않는다
        let freqs = r.filters.map(\.frequencyHz)
        #expect(Set(freqs).count == freqs.count)
        // 63 Hz 피크 컷이 있다
        #expect(r.filters.contains { abs(log2($0.frequencyHz / 63)) < 0.3 && $0.gainDB < -3 })
        let table = EQAssignment.markdownTable(EQAssignment.fromResult(r))
        #expect(table.contains("Main L/R"))
        let summary = MeasurementSummary.from(r, positions: 5, microphone: "sim", feedback: [])
        #expect(summary.proposedFilters.count == r.filters.count)
    }

    @Test func wavWriterHeader() {
        let d = WAVWriter.data(samples: [0, 0.5, -0.5], sampleRate: 48_000, bitsPerSample: 24)
        #expect(d.count == 44 + 9)
        #expect(String(decoding: d[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: d[8..<12], as: UTF8.self) == "WAVE")
        let d16 = WAVWriter.data(samples: [1.0], sampleRate: 44_100, bitsPerSample: 16)
        #expect(d16[44] == 0xFF && d16[45] == 0x7F)
    }

    @Test func storeRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tunemate-test-\(UUID().uuidString)")
        let store = AppStore(root: root)
        var s = await store.settings
        s.provider = .gemini; s.chatTier = .economy; s.mixerFamily = .behringerXAir; s.mixerModelName = MixerModel.xr18.name
        await store.saveSettings(s)
        var session = MeasurementSession(venueName: "본당", microphone: .umik1)
        session.positions.append(PositionMeasurement(name: "A", response: FrequencyResponse(frequencies: [100, 1000], magnitudesDB: [70, 70]), microphone: .umik1))
        await store.save(session)
        let store2 = AppStore(root: root)
        #expect(await store2.settings.provider == .gemini)
        #expect(await store2.settings.mixerModel == .xr18)
        #expect(await store2.sessions.first?.venueName == "본당")
        await store2.delete(session.id)
        #expect(await store2.sessions.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }
}
