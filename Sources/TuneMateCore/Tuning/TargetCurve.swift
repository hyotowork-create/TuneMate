import Foundation

/// 목표 곡선: 평탄 + 고역 완만 하강 (설정에서 변경 가능).
public struct TargetCurve: Codable, Equatable, Hashable, Sendable {
    /// 이 주파수 위로 기울기를 적용한다.
    public var kneeHz: Double
    /// 옥타브당 dB (음수 = 하강). 기본 −1 dB/oct → 20 kHz에서 약 −4.3 dB.
    public var slopeDBPerOctave: Double
    /// 저역 셸프(선택): kneeLowHz 아래로 +dB. 예배당은 보통 0.
    public var lowShelfDB: Double
    public var lowKneeHz: Double

    public init(kneeHz: Double = 1_000, slopeDBPerOctave: Double = -1.0, lowShelfDB: Double = 0, lowKneeHz: Double = 100) {
        self.kneeHz = kneeHz
        self.slopeDBPerOctave = slopeDBPerOctave
        self.lowShelfDB = lowShelfDB
        self.lowKneeHz = lowKneeHz
    }

    public static let flat = TargetCurve(slopeDBPerOctave: 0)
    public static let speech = TargetCurve(kneeHz: 1_000, slopeDBPerOctave: -1.0)
    public static let worshipMusic = TargetCurve(kneeHz: 800, slopeDBPerOctave: -1.5, lowShelfDB: 2, lowKneeHz: 120)

    public func value(at hz: Double) -> Double {
        var v = 0.0
        if hz > kneeHz { v += slopeDBPerOctave * log2(hz / kneeHz) }
        if lowShelfDB != 0 && hz < lowKneeHz {
            // 부드러운 셸프: 한 옥타브에 걸쳐 전이
            let t = min(1, max(0, log2(lowKneeHz / hz)))
            v += lowShelfDB * t
        }
        return v
    }

    public func response(on grid: [Double]) -> FrequencyResponse {
        FrequencyResponse(frequencies: grid, magnitudesDB: grid.map(value(at:)))
    }
}
