import Foundation

/// 입력 레벨(dBFS) 계산 — 측정 전 신호가 들어오는지, 클립되는지 확인용.
public struct InputLevel: Equatable, Sendable {
    public var rmsDB: Double
    public var peakDB: Double
    public var clipped: Bool
    public init(rmsDB: Double, peakDB: Double, clipped: Bool) { self.rmsDB = rmsDB; self.peakDB = peakDB; self.clipped = clipped }

    public static func measure(_ samples: [Double]) -> InputLevel {
        guard !samples.isEmpty else { return InputLevel(rmsDB: -120, peakDB: -120, clipped: false) }
        var sum = 0.0, peak = 0.0
        for s in samples { sum += s * s; peak = max(peak, abs(s)) }
        return InputLevel(rmsDB: Decibel.fromAmplitude((sum / Double(samples.count)).squareRoot()), peakDB: Decibel.fromAmplitude(peak), clipped: peak >= 0.99)
    }

    /// 측정에 알맞은 레벨인지 (RMS −40 ~ −6 dBFS)
    public var advice: String {
        if clipped { return "클립됩니다. 믹서 출력 또는 마이크 게인을 낮추세요." }
        if rmsDB < -60 { return "신호가 거의 없습니다. 마이크 연결과 테스트 신호 경로를 확인하세요." }
        if rmsDB < -40 { return "신호가 작습니다. 재생 레벨을 올리세요." }
        if rmsDB > -6 { return "레벨이 높습니다. 조금 낮추세요." }
        return "측정에 알맞은 레벨입니다."
    }
}
