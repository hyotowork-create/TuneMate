import Foundation

/// 공간 튜닝 루프 (기획서 8장): 측정 → 계산 → 적용 → 재측정을 목표에 들 때까지 최대 N회 반복.
/// 적용 단계는 사람 승인 뒤에만 수행되므로, 이 타입은 '판정'과 '다음 단계 안내'만 맡는다.
public struct TuningIteration: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var index: Int                      // 1부터
    public var measuredAt: Date = Date()
    public var filters: [EQFilter]             // 이 회차에 적용한(또는 제안한) 필터
    public var predictedRMSDB: Double          // 적용 전 예상 잔차
    public var verifiedRMSDB: Double?          // 재측정 잔차 (없으면 아직 검증 전)
    public var verifiedResponse: FrequencyResponse?
    public var predictionErrorRMSDB: Double?   // 예상 vs 실측 차이

    public init(index: Int, filters: [EQFilter], predictedRMSDB: Double) {
        self.index = index; self.filters = filters; self.predictedRMSDB = predictedRMSDB
    }
}

public enum TuningVerdict: Equatable, Sendable {
    case notVerified                              // 적용 후 재측정이 아직 없음
    case converged(residualDB: Double)            // 목표 안
    case improving(residualDB: Double)            // 좋아지고 있음 → 한 번 더
    case stalled(residualDB: Double, reason: String) // 수렴 안 함 → EQ 밖 원인
    case limitReached(residualDB: Double)         // 최대 회차 도달

    public var residual: Double? {
        switch self { case .notVerified: return nil; case .converged(let r), .improving(let r), .stalled(let r, _), .limitReached(let r): return r }
    }
    public var shouldContinue: Bool { if case .improving = self { return true }; return false }
    public var displayText: String {
        switch self {
        case .notVerified: return "적용 후 같은 위치에서 재측정하면 판정합니다."
        case .converged(let r): return String(format: "수렴: 목표 대비 잔차 %.1f dB. 튜닝 완료.", r)
        case .improving(let r): return String(format: "개선 중: 잔차 %.1f dB. 한 번 더 계산·적용·재측정하세요.", r)
        case .stalled(let r, let reason): return String(format: "수렴하지 않음 (잔차 %.1f dB): %@", r, reason)
        case .limitReached(let r): return String(format: "최대 반복 도달 (잔차 %.1f dB). 남은 편차는 스피커 위치·반사 쪽입니다.", r)
        }
    }
}

public struct TuningLoopOptions: Codable, Equatable, Sendable {
    public var maxIterations: Int = 3
    /// 이 잔차(RMS dB) 이하면 수렴
    public var targetResidualDB: Double = 1.5
    /// 회차 간 개선이 이보다 작으면 정체
    public var minImprovementDB: Double = 0.5
    /// 예상과 실측이 이보다 크게 다르면 EQ 모델이 안 맞는 것(필터 수·Q 해석 차이, 믹서 EQ 꺼짐 등)
    public var maxPredictionErrorDB: Double = 2.0
    public init() {}
}

public enum TuningLoop {
    /// 검증 응답(재측정 평균)을 회차에 기록하고 판정한다.
    public static func verify(iteration: inout TuningIteration, verified: FrequencyResponse, target: TargetCurve, predicted: FrequencyResponse,
                              autoEQ: AutoEQOptions, previous: TuningIteration?, options: TuningLoopOptions) -> TuningVerdict {
        let grid = predicted.frequencies
        let targetResp = target.response(on: grid)
        let smoothed = verified.smoothed(fractionOfOctave: autoEQ.smoothingFraction)
        let offset = targetResp.meanDB(in: autoEQ.levelMatchBand) - smoothed.meanDB(in: autoEQ.levelMatchBand)
        let aligned = smoothed.offset(by: offset)
        // 예상 곡선도 같은 대역 평균으로 정렬해 '모양'만 비교한다
        let predictedAligned = predicted.offset(by: targetResp.meanDB(in: autoEQ.levelMatchBand) - predicted.meanDB(in: autoEQ.levelMatchBand))
        let mask = grid.map { $0 >= autoEQ.minFrequencyHz && $0 <= autoEQ.maxFrequencyHz }
        let residual = rms(aligned.subtracting(targetResp).magnitudesDB, mask: mask)
        let predErr = rms(aligned.subtracting(predictedAligned).magnitudesDB, mask: mask)
        iteration.verifiedRMSDB = residual
        iteration.verifiedResponse = aligned
        iteration.predictionErrorRMSDB = predErr

        if residual <= options.targetResidualDB { return .converged(residualDB: residual) }
        if predErr > options.maxPredictionErrorDB {
            return .stalled(residualDB: residual, reason: String(format: "예상과 실측이 %.1f dB 다릅니다. 믹서 EQ가 켜져 있는지, 밴드 값이 그대로 들어갔는지, 측정 위치가 같은지 확인하세요.", predErr))
        }
        if let prev = previous, let prevRes = prev.verifiedRMSDB, prevRes - residual < options.minImprovementDB {
            return .stalled(residualDB: residual, reason: "회차 간 개선이 작습니다. 남은 편차는 EQ로 안 잡히는 방 구조(딥·반사)나 스피커 위치입니다.")
        }
        if iteration.index >= options.maxIterations { return .limitReached(residualDB: residual) }
        return .improving(residualDB: residual)
    }

    static func rms(_ e: [Double], mask: [Bool]) -> Double {
        var s = 0.0, c = 0
        for (i, v) in e.enumerated() where mask[i] { s += v * v; c += 1 }
        return c > 0 ? (s / Double(c)).squareRoot() : 0
    }
}
