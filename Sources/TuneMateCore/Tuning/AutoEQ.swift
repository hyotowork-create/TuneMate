import Foundation

/// 보정 EQ 산출. 컷 우선, 부스트 소폭, 깊은 딥 제외, 밴드 수 제한.
public struct AutoEQOptions: Codable, Equatable, Sendable {
    /// 사용할 수 있는 필터(밴드) 수 — 메인 출력 EQ 가용 밴드 수에 맞춘다.
    public var maxFilters: Int = 8
    public var maxBoostDB: Double = 3
    public var maxCutDB: Double = -12
    public var minFrequencyHz: Double = 40
    public var maxFrequencyHz: Double = 16_000
    /// 이보다 깊이 꺼진 구간(목표 대비, dB)은 방 구조 딥으로 보고 제외
    public var dipExclusionDB: Double = -8
    /// 딥 양쪽 어깨도 함께 제외하는 폭(옥타브) — 어깨를 부스트로 메우지 않도록
    public var dipMarginOctaves: Double = 1.0 / 3.0
    public var minQ: Double = 0.5
    public var maxQ: Double = 10
    /// 이 이하 오차는 보정하지 않음
    public var toleranceDB: Double = 1.0
    /// 레벨 맞춤 대역
    public var levelMatchBand: ClosedRange<Double> = 200...2_000
    /// 스무딩 (1/N 옥타브)
    public var smoothingFraction: Double = 6

    public init() {}
}

public struct AutoEQResult: Codable, Equatable, Sendable {
    public var filters: [EQFilter]
    /// 레벨 정렬 후 측정 응답
    public var measured: FrequencyResponse
    public var target: FrequencyResponse
    /// 필터 적용 예상 응답
    public var predicted: FrequencyResponse
    public var residualRMSDB: Double
    public var initialRMSDB: Double
    /// 제외된 딥 구간 (Hz)
    public var excludedDips: [ClosedRange<Double>]
    /// EQ로 해결되지 않는 항목 메모 (사람·AI가 읽는 설명)
    public var notes: [String]
}

public enum AutoEQ {
    public static func compute(response raw: FrequencyResponse, target: TargetCurve, options: AutoEQOptions = AutoEQOptions()) -> AutoEQResult {
        let grid = raw.frequencies
        let smoothed = raw.smoothed(fractionOfOctave: options.smoothingFraction)
        let targetResp = target.response(on: grid)
        // 레벨 정렬: 대역 평균이 목표와 같도록
        let offset = targetResp.meanDB(in: options.levelMatchBand) - smoothed.meanDB(in: options.levelMatchBand)
        let measured = smoothed.offset(by: offset)

        var error = measured.subtracting(targetResp).magnitudesDB // + = 너무 큼 → 컷
        let n = grid.count
        var mask = [Bool](repeating: true, count: n)
        var excluded: [ClosedRange<Double>] = []
        var notes: [String] = []

        // 범위 밖·딥 제외
        var dipStart: Int? = nil
        for i in 0..<n {
            let f = grid[i]
            let inRange = f >= options.minFrequencyHz && f <= options.maxFrequencyHz
            let deepDip = error[i] < options.dipExclusionDB
            mask[i] = inRange && !deepDip
            if deepDip && inRange {
                if dipStart == nil { dipStart = i }
            } else if let s = dipStart {
                excluded.append(grid[s]...grid[i - 1]); dipStart = nil
            }
        }
        if let s = dipStart { excluded.append(grid[s]...grid[n - 1]) }
        // 딥 어깨 제외
        let margin = pow(2, options.dipMarginOctaves)
        for d in excluded {
            for i in 0..<n where grid[i] >= d.lowerBound / margin && grid[i] <= d.upperBound * margin { mask[i] = false }
        }
        for d in excluded {
            notes.append(String(format: "%.0f–%.0f Hz 깊은 딥은 EQ로 채우지 않습니다 (방 구조·스피커 위치 점검 대상).", d.lowerBound, d.upperBound))
        }

        // 평가 구간(범위 안 + 딥·어깨 제외)은 필터 배정 중에 줄어드는 선택용 mask 와 따로 둔다.
        // 적용 전·후 RMS 와 검증 루프의 실측 잔차가 모두 이 같은 구간으로 계산되어야 숫자를 비교할 수 있다.
        let evalMask = mask
        let initialRMS = rms(error, mask: evalMask)
        var filters: [EQFilter] = []
        let ppo = measured.pointsPerOctave

        for _ in 0..<max(0, options.maxFilters) {
            // 가장 큰 오차 (컷 우선: 양의 오차 가중 1.0, 음의 오차 0.7)
            var bestIdx = -1
            var bestScore = 0.0
            for i in 0..<n where mask[i] {
                let e = error[i]
                let score = e > 0 ? e : -e * 0.7
                if score > bestScore { bestScore = score; bestIdx = i }
            }
            guard bestIdx >= 0, abs(error[bestIdx]) > options.toleranceDB else { break }

            let fc = grid[bestIdx]
            let peak = error[bestIdx]
            // 반값 폭으로 Q 추정
            let half = peak / 2
            var lo = bestIdx, hi = bestIdx
            while lo > 0 && (peak > 0 ? error[lo] > half : error[lo] < half) { lo -= 1 }
            while hi < n - 1 && (peak > 0 ? error[hi] > half : error[hi] < half) { hi += 1 }
            let widthOct = Double(max(1, hi - lo)) / ppo
            var q = min(options.maxQ, max(options.minQ, 1.0 / max(0.05, widthOct) * 1.2))
            var gain = clampGain(-peak, options)

            // 국소 격자 탐색으로 gain·Q 정제 (오차 RMS 최소화, 피크 ±1옥타브 안)
            let winLo = max(0, bestIdx - Int(ppo)), winHi = min(n - 1, bestIdx + Int(ppo))
            var bestCost = Double.infinity
            var bestG = gain, bestQ = q
            for gm in [0.6, 0.8, 1.0, 1.15] {
                for qm in [0.5, 0.75, 1.0, 1.5, 2.0] {
                    let g = clampGain(gain * gm, options)
                    let qq = min(options.maxQ, max(options.minQ, q * qm))
                    let f = EQFilter(frequencyHz: fc, gainDB: g, q: qq)
                    var cost = 0.0
                    for i in winLo...winHi where mask[i] {
                        let r = error[i] + f.magnitudeDB(at: grid[i])
                        cost += r * r
                    }
                    if cost < bestCost { bestCost = cost; bestG = g; bestQ = qq }
                }
            }
            gain = bestG; q = bestQ
            if abs(gain) < 0.25 { break }
            let filter = EQFilter(frequencyHz: roundFrequency(fc), gainDB: (gain * 10).rounded() / 10, q: (q * 10).rounded() / 10)
            filters.append(filter)
            for i in 0..<n { error[i] += filter.magnitudeDB(at: grid[i]) }
            // 같은 자리에 필터가 겹치지 않도록: 중심 ±1/12 옥타브, 부스트 한도에 닿았으면 필터 폭 전체를 선택에서 제외
            let exclude = gain >= options.maxBoostDB - 1e-9 ? max(1.0 / 12, 1 / (2 * q)) : 1.0 / 12
            for i in 0..<n where abs(log2(grid[i] / fc)) <= exclude { mask[i] = false }
        }

        filters.sort { $0.frequencyHz < $1.frequencyHz }
        let predicted = measured.adding(EQFilter.combinedResponse(filters, on: grid))
        let residual = rms(predicted.subtracting(targetResp).magnitudesDB, mask: evalMask)
        if filters.contains(where: { $0.gainDB >= options.maxBoostDB - 0.05 }) {
            notes.append("부스트 한도(+\(Int(options.maxBoostDB)) dB)에 닿은 밴드가 있습니다. 부족한 대역은 스피커 배치로 보는 편이 안전합니다.")
        }
        return AutoEQResult(filters: filters, measured: measured, target: targetResp, predicted: predicted,
                            residualRMSDB: residual, initialRMSDB: initialRMS, excludedDips: excluded, notes: notes)
    }

    /// 잔차를 계산하는 구간: 보정 범위 안이면서, 제외한 딥과 그 어깨(dipMarginOctaves)가 아닌 곳.
    /// `compute` 가 쓰는 평가 구간과 같다 — 검증 루프가 같은 기준으로 실측 잔차를 내도록 공개한다.
    public static func evaluationMask(grid: [Double], options: AutoEQOptions, excludedDips: [ClosedRange<Double>]) -> [Bool] {
        let margin = pow(2, options.dipMarginOctaves)
        return grid.map { f in
            guard f >= options.minFrequencyHz && f <= options.maxFrequencyHz else { return false }
            return !excludedDips.contains { f >= $0.lowerBound / margin && f <= $0.upperBound * margin }
        }
    }

    private static func clampGain(_ g: Double, _ o: AutoEQOptions) -> Double { min(o.maxBoostDB, max(o.maxCutDB, g)) }

    private static func rms(_ e: [Double], mask: [Bool]) -> Double {
        var s = 0.0, c = 0
        for (i, v) in e.enumerated() where mask[i] { s += v * v; c += 1 }
        return c > 0 ? (s / Double(c)).squareRoot() : 0
    }

    /// 믹서에 입력하기 쉬운 값으로 반올림 (3자리 유효숫자)
    public static func roundFrequency(_ f: Double) -> Double {
        if f < 100 { return (f * 10).rounded() / 10 }
        if f < 1_000 { return f.rounded() }
        return (f / 10).rounded() * 10
    }
}

/// 보정값 출력 형식: 대상 출력, 밴드 번호, 주파수, 게인, Q
public struct EQAssignment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var target: String
    public var band: Int
    public var frequencyHz: Double
    public var gainDB: Double
    public var q: Double

    public init(target: String, band: Int, frequencyHz: Double, gainDB: Double, q: Double) {
        self.target = target; self.band = band; self.frequencyHz = frequencyHz; self.gainDB = gainDB; self.q = q
    }

    public static func fromResult(_ r: AutoEQResult, target: String = "Main L/R", startingBand: Int = 1) -> [EQAssignment] {
        r.filters.enumerated().map { EQAssignment(target: target, band: startingBand + $0.offset, frequencyHz: $0.element.frequencyHz, gainDB: $0.element.gainDB, q: $0.element.q) }
    }

    /// 아이패드 공식 앱에 직접 입력할 표 (Phase 1 수동 적용용)
    public static func markdownTable(_ rows: [EQAssignment]) -> String {
        var s = "| 대상 | 밴드 | 주파수(Hz) | 게인(dB) | Q |\n|---|---|---|---|---|\n"
        for r in rows {
            s += String(format: "| %@ | %d | %.0f | %+.1f | %.1f |\n", r.target, r.band, r.frequencyHz, r.gainDB, r.q)
        }
        return s
    }
}
