import Foundation

/// 측정 세션 → Markdown 리포트 (공유·기록용).
public enum MeasurementReport {
    public static func markdown(_ s: MeasurementSession, venue: VenueProfile, mixer: MixerModel, iterations: [TuningIteration] = [], verdict: TuningVerdict? = nil) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "ko_KR"); df.dateFormat = "yyyy-MM-dd HH:mm"
        var md = "# 공간 측정 리포트 — \(s.venueName)\n\n"
        md += "- 측정 시각: \(df.string(from: s.createdAt))\n"
        md += "- 믹서: \(mixer.displayName)\n- 마이크: \(s.microphone.displayName)\n"
        md += String(format: "- 스윕: %.0f–%.0f Hz, %.0f초, %.0f kHz\n", s.sweep.startHz, s.sweep.endHz, s.sweep.durationSeconds, s.sweep.sampleRate / 1000)
        md += "- 좌석: \(venue.seats), 스피커: \(venue.speakerLayout)\n"
        md += "- 목표 곡선: \(targetName(s.target))\n\n"
        md += "## 측정 위치 (\(s.positions.count))\n\n| 위치 | 200–2k 평균(dB) | 지연(ms) |\n|---|---|---|\n"
        for p in s.positions {
            md += String(format: "| %@ | %.1f | %@ |\n", p.name, p.response.meanDB(in: 200...2000), p.irPeakTimeMs.map { String(format: "%.1f", $0) } ?? "-")
        }
        if let dev = s.deviation { md += String(format: "\n좌석 간 편차(100 Hz–8 kHz): %.1f dB RMS\n", dev.meanDB(in: 100...8000)) }
        if let r = s.result {
            md += String(format: "\n## 보정값 (목표 대비 RMS 오차 %.1f → %.1f dB 예상)\n\n", r.initialRMSDB, r.residualRMSDB)
            md += EQAssignment.markdownTable(EQAssignment.fromResult(r))
            if !r.excludedDips.isEmpty { md += "\n제외한 딥: " + r.excludedDips.map { String(format: "%.0f–%.0f Hz", $0.lowerBound, $0.upperBound) }.joined(separator: ", ") + "\n" }
            for n in r.notes { md += "- " + n + "\n" }
            md += "\n### 1/3옥타브 편차 (목표 대비)\n\n| 주파수 | 측정 | 예상 |\n|---|---|---|\n"
            for c in [31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000] {
                let t = r.target.magnitudeDB(at: c)
                md += String(format: "| %@ | %+.1f | %+.1f |\n", c >= 1000 ? String(format: "%.2gk", c / 1000) : String(format: "%.0f", c), r.measured.magnitudeDB(at: c) - t, r.predicted.magnitudeDB(at: c) - t)
            }
        }
        if !iterations.isEmpty {
            md += "\n## 튜닝 반복\n\n| 회차 | 필터 | 예상 잔차 | 실측 잔차 | 예상-실측 차 |\n|---|---|---|---|---|\n"
            for it in iterations {
                md += String(format: "| %d | %d | %.1f | %@ | %@ |\n", it.index, it.filters.count, it.predictedRMSDB,
                             it.verifiedRMSDB.map { String(format: "%.1f", $0) } ?? "-", it.predictionErrorRMSDB.map { String(format: "%.1f", $0) } ?? "-")
            }
            if let v = verdict { md += "\n판정: " + v.displayText + "\n" }
        }
        if !s.notes.isEmpty { md += "\n## 메모\n\n\(s.notes)\n" }
        md += "\n---\n튠메이트 \(TuneMateInfo.version) · \(TuneMateInfo.disclaimer)\n"
        return md
    }

    static func targetName(_ t: TargetCurve) -> String {
        if t == .flat { return "평탄" }
        if t == .speech { return "설교 중심 (1 kHz 위 −1 dB/oct)" }
        if t == .worshipMusic { return "찬양 중심" }
        return String(format: "사용자 (%.0f Hz 위 %.1f dB/oct)", t.kneeHz, t.slopeDBPerOctave)
    }
}
