import Foundation

/// 로그 간격 주파수 격자 위의 응답. 모든 분석·보정은 이 형식을 쓴다.
public struct FrequencyResponse: Codable, Equatable, Sendable {
    public var frequencies: [Double]
    public var magnitudesDB: [Double]

    public init(frequencies: [Double], magnitudesDB: [Double]) {
        precondition(frequencies.count == magnitudesDB.count)
        self.frequencies = frequencies
        self.magnitudesDB = magnitudesDB
    }

    public var count: Int { frequencies.count }

    /// 표준 격자: 옥타브당 ppo 점, [lowHz, highHz].
    public static func logGrid(lowHz: Double = 20, highHz: Double = 20_000, pointsPerOctave ppo: Int = 48) -> [Double] {
        let octaves = log2(highHz / lowHz)
        let n = Int((octaves * Double(ppo)).rounded(.down)) + 1
        return (0..<n).map { lowHz * pow(2, Double($0) / Double(ppo)) }
    }

    /// 선형 스펙트럼을 로그 격자로 다시 표본화한다.
    public static func fromLinear(_ s: LinearSpectrum, grid: [Double] = logGrid()) -> FrequencyResponse {
        FrequencyResponse(frequencies: grid, magnitudesDB: grid.map { s.magnitudeDB(at: $0) })
    }

    /// 격자의 옥타브당 점 수 (등간격 로그 격자 가정).
    public var pointsPerOctave: Double {
        guard count > 1 else { return 0 }
        return 1 / log2(frequencies[1] / frequencies[0])
    }

    /// 1/N 옥타브 스무딩 (파워 평균).
    public func smoothed(fractionOfOctave n: Double) -> FrequencyResponse {
        guard n > 0, count > 2 else { return self }
        let ppo = pointsPerOctave
        let halfWidth = max(1, Int((ppo / n / 2).rounded()))
        var out = [Double](repeating: 0, count: count)
        let power = magnitudesDB.map { Decibel.toPower($0) }
        // 누적합으로 O(n)
        var prefix = [Double](repeating: 0, count: count + 1)
        for i in 0..<count { prefix[i + 1] = prefix[i] + power[i] }
        for i in 0..<count {
            let lo = max(0, i - halfWidth)
            let hi = min(count - 1, i + halfWidth)
            let mean = (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
            out[i] = Decibel.fromPower(mean)
        }
        return FrequencyResponse(frequencies: frequencies, magnitudesDB: out)
    }

    /// 선형 보간(로그 주파수 축)으로 임의 주파수의 값을 구한다.
    public func magnitudeDB(at hz: Double) -> Double {
        guard count > 0 else { return Decibel.floor }
        if hz <= frequencies[0] { return magnitudesDB[0] }
        if hz >= frequencies[count - 1] { return magnitudesDB[count - 1] }
        var lo = 0, hi = count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if frequencies[mid] <= hz { lo = mid } else { hi = mid }
        }
        let t = log(hz / frequencies[lo]) / log(frequencies[hi] / frequencies[lo])
        return magnitudesDB[lo] * (1 - t) + magnitudesDB[hi] * t
    }

    /// 대역 내 평균 dB (파워 평균).
    public func meanDB(in band: ClosedRange<Double>) -> Double {
        var sum = 0.0, n = 0
        for (f, m) in zip(frequencies, magnitudesDB) where band.contains(f) { sum += Decibel.toPower(m); n += 1 }
        return n > 0 ? Decibel.fromPower(sum / Double(n)) : 0
    }

    public func offset(by db: Double) -> FrequencyResponse {
        FrequencyResponse(frequencies: frequencies, magnitudesDB: magnitudesDB.map { $0 + db })
    }

    /// 다른 응답을 이 격자에 맞춰 뺀다 (self − other).
    public func subtracting(_ other: FrequencyResponse) -> FrequencyResponse {
        FrequencyResponse(frequencies: frequencies,
                          magnitudesDB: zip(frequencies, magnitudesDB).map { $1 - other.magnitudeDB(at: $0) })
    }

    public func adding(_ other: FrequencyResponse) -> FrequencyResponse {
        FrequencyResponse(frequencies: frequencies,
                          magnitudesDB: zip(frequencies, magnitudesDB).map { $1 + other.magnitudeDB(at: $0) })
    }

    /// 여러 위치 응답의 공간 평균 (파워 평균). 격자는 첫 응답을 따른다.
    public static func spatialAverage(_ responses: [FrequencyResponse]) -> FrequencyResponse? {
        guard let first = responses.first else { return nil }
        var acc = [Double](repeating: 0, count: first.count)
        for r in responses {
            for (i, f) in first.frequencies.enumerated() { acc[i] += Decibel.toPower(r.magnitudeDB(at: f)) }
        }
        let n = Double(responses.count)
        return FrequencyResponse(frequencies: first.frequencies, magnitudesDB: acc.map { Decibel.fromPower($0 / n) })
    }

    /// 위치별 편차(표준편차, dB) — 좌석 간 일관성 지표.
    public static func spatialDeviation(_ responses: [FrequencyResponse]) -> FrequencyResponse? {
        guard let avg = spatialAverage(responses), responses.count > 1 else { return nil }
        var acc = [Double](repeating: 0, count: avg.count)
        for r in responses {
            for (i, f) in avg.frequencies.enumerated() {
                let d = r.magnitudeDB(at: f) - avg.magnitudesDB[i]
                acc[i] += d * d
            }
        }
        return FrequencyResponse(frequencies: avg.frequencies, magnitudesDB: acc.map { ($0 / Double(responses.count)).squareRoot() })
    }
}
