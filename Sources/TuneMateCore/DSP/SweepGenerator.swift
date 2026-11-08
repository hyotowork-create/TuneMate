import Foundation

/// 로그 사인 스윕 (Farina 방식) 생성기.
public struct SweepSpec: Codable, Equatable, Sendable {
    public var sampleRate: Double
    public var startHz: Double
    public var endHz: Double
    public var durationSeconds: Double
    /// 스윕 앞뒤 무음(초). 뒤쪽 무음은 잔향을 담는 데 쓰인다.
    public var leadInSeconds: Double
    public var tailSeconds: Double
    /// 0~1 진폭. 디지털 클립을 피하기 위해 기본 0.5(-6 dBFS).
    public var amplitude: Double
    /// 시작·끝 페이드(초). 스펙트럼 누설 억제.
    public var fadeSeconds: Double

    public init(sampleRate: Double = 48_000, startHz: Double = 20, endHz: Double = 20_000,
                durationSeconds: Double = 10, leadInSeconds: Double = 0.5, tailSeconds: Double = 2.0,
                amplitude: Double = 0.5, fadeSeconds: Double = 0.05) {
        self.sampleRate = sampleRate
        self.startHz = startHz
        self.endHz = endHz
        self.durationSeconds = durationSeconds
        self.leadInSeconds = leadInSeconds
        self.tailSeconds = tailSeconds
        self.amplitude = amplitude
        self.fadeSeconds = fadeSeconds
    }

    public static let `default` = SweepSpec()
    public static let quick = SweepSpec(durationSeconds: 5, tailSeconds: 1.5)

    public var sweepSampleCount: Int { Int(durationSeconds * sampleRate) }
    public var totalSampleCount: Int { Int((leadInSeconds + durationSeconds + tailSeconds) * sampleRate) }
    public var leadInSampleCount: Int { Int(leadInSeconds * sampleRate) }
}

public enum SweepGenerator {
    /// 무음 없이 스윕 구간만 생성한다.
    public static func sweep(_ spec: SweepSpec) -> [Double] {
        let n = spec.sweepSampleCount
        guard n > 0 else { return [] }
        let T = spec.durationSeconds
        let k = log(spec.endHz / spec.startHz)
        let a = 2 * Double.pi * spec.startHz * T / k
        var out = [Double](repeating: 0, count: n)
        let fadeN = max(1, Int(spec.fadeSeconds * spec.sampleRate))
        for i in 0..<n {
            let t = Double(i) / spec.sampleRate
            let phase = a * (exp(t / T * k) - 1)
            var env = 1.0
            if i < fadeN { env = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fadeN)) }
            else if i >= n - fadeN { env = 0.5 - 0.5 * cos(Double.pi * Double(n - 1 - i) / Double(fadeN)) }
            out[i] = spec.amplitude * env * sin(phase)
        }
        return out
    }

    /// 앞 무음 + 스윕 + 뒤 무음을 합친 재생용 신호.
    public static func playbackSignal(_ spec: SweepSpec) -> [Double] {
        let lead = [Double](repeating: 0, count: spec.leadInSampleCount)
        let tail = [Double](repeating: 0, count: Int(spec.tailSeconds * spec.sampleRate))
        return lead + sweep(spec) + tail
    }

    /// 핑크 노이즈 (Voss-McCartney 근사). RTA 확인용.
    public static func pinkNoise(sampleCount: Int, amplitude: Double = 0.3, seed: UInt64 = 0x5EED) -> [Double] {
        var rng = SplitMix64(seed: seed)
        let rows = 16
        var rowValues = [Double](repeating: 0, count: rows)
        for r in 0..<rows { rowValues[r] = rng.nextUniform() * 2 - 1 }
        var runningSum = rowValues.reduce(0, +)
        var out = [Double](repeating: 0, count: sampleCount)
        var counter: UInt64 = 0
        for i in 0..<sampleCount {
            counter &+= 1
            let r = counter.trailingZeroBitCount
            if r < rows {
                runningSum -= rowValues[r]
                rowValues[r] = rng.nextUniform() * 2 - 1
                runningSum += rowValues[r]
            }
            let white = rng.nextUniform() * 2 - 1
            out[i] = amplitude * (runningSum + white) / Double(rows + 1)
        }
        return out
    }
}

/// 결정적 난수 (테스트 재현용).
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    public mutating func nextUniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
