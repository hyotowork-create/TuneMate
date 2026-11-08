import Foundation

public enum EQFilterType: String, Codable, Sendable, CaseIterable {
    case peaking, lowShelf, highShelf, lowCut, highCut, notch
}

/// 파라메트릭 EQ 한 밴드. 아날로그 프로토타입 크기 응답으로 계산한다 (믹서 DSP 근사).
public struct EQFilter: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var type: EQFilterType
    public var frequencyHz: Double
    public var gainDB: Double
    public var q: Double
    public var enabled: Bool

    public init(id: UUID = UUID(), type: EQFilterType = .peaking, frequencyHz: Double, gainDB: Double, q: Double, enabled: Bool = true) {
        self.id = id
        self.type = type
        self.frequencyHz = frequencyHz
        self.gainDB = gainDB
        self.q = q
        self.enabled = enabled
    }

    /// 주파수 f 에서의 크기(dB).
    public func magnitudeDB(at f: Double) -> Double {
        guard enabled else { return 0 }
        let w = f / frequencyHz // 정규화 주파수 (ω/ω0)
        switch type {
        case .peaking, .notch:
            let g = type == .notch ? min(gainDB, -0.01) : gainDB
            let A = pow(10, g / 40)
            let qq = max(0.05, q)
            // |H| = |(1 - w²) + j w A/Q| / |(1 - w²) + j w /(A Q)|
            let re = 1 - w * w
            let numIm = w * A / qq
            let denIm = w / (A * qq)
            let num = (re * re + numIm * numIm).squareRoot()
            let den = (re * re + denIm * denIm).squareRoot()
            return Decibel.fromAmplitude(num / den)
        case .lowShelf, .highShelf:
            // 1차 셸프 근사 (Q는 전이 폭에 약간 영향; 단순화)
            let A = pow(10, gainDB / 20)
            let x = type == .lowShelf ? 1 / w : w
            // 전이: 0 dB (x≪1) → gain (x≫1)
            let t = (x * x) / (1 + x * x)
            return Decibel.fromAmplitude(1 + (A - 1) * t)
        case .lowCut:
            // 2차 버터워스 HPF
            let n = w * w
            return Decibel.fromAmplitude(n / (1 + n * n).squareRoot())
        case .highCut:
            let n = w * w
            return Decibel.fromAmplitude(1 / (1 + n * n).squareRoot())
        }
    }

    public func response(on grid: [Double]) -> FrequencyResponse {
        FrequencyResponse(frequencies: grid, magnitudesDB: grid.map(magnitudeDB(at:)))
    }

    public static func combinedResponse(_ filters: [EQFilter], on grid: [Double]) -> FrequencyResponse {
        var acc = [Double](repeating: 0, count: grid.count)
        for f in filters where f.enabled {
            for (i, hz) in grid.enumerated() { acc[i] += f.magnitudeDB(at: hz) }
        }
        return FrequencyResponse(frequencies: grid, magnitudesDB: acc)
    }
}
