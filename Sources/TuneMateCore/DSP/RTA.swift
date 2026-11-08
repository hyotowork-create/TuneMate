import Foundation
import Accelerate

/// 실시간 분석기: 입력 블록을 받아 로그 격자 스펙트럼 프레임을 만든다.
/// 하울링 검출·핑크노이즈 확인에 쓰인다.
public final class RealTimeAnalyzer {
    public let sampleRate: Double
    public let fftSize: Int
    public let grid: [Double]
    private let fft: FFT
    private var window: [Double]
    private var ring: [Double]
    private var ringFill = 0
    private var averaged: [Double]?
    /// 지수 평균 계수 (0 = 평균 없음, 0.8 = 느린 평균)
    public var averaging: Double

    public init(sampleRate: Double = 48_000, fftSize: Int = 8192, pointsPerOctave: Int = 24, averaging: Double = 0.5) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.grid = FrequencyResponse.logGrid(lowHz: 20, highHz: min(20_000, sampleRate / 2 * 0.95), pointsPerOctave: pointsPerOctave)
        self.fft = FFT(size: fftSize)
        self.averaging = averaging
        self.window = (0..<fftSize).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize)) } // Hann
        self.ring = [Double](repeating: 0, count: fftSize)
    }

    public func reset() { averaged = nil; ringFill = 0 }

    /// 샘플을 밀어 넣고, 창이 채워졌으면 프레임을 돌려준다. (hop = fftSize/2)
    public func push(_ samples: [Double]) -> [SpectrumFrame] {
        var frames: [SpectrumFrame] = []
        var idx = 0
        while idx < samples.count {
            let take = min(samples.count - idx, fftSize - ringFill)
            for i in 0..<take { ring[ringFill + i] = samples[idx + i] }
            ringFill += take
            idx += take
            if ringFill == fftSize {
                frames.append(analyze(ring))
                // hop 50%
                let hop = fftSize / 2
                for i in 0..<(fftSize - hop) { ring[i] = ring[i + hop] }
                ringFill = fftSize - hop
            }
        }
        return frames
    }

    /// 단일 블록(길이 fftSize) 분석.
    public func analyze(_ block: [Double]) -> SpectrumFrame {
        var x = [Double](repeating: 0, count: fftSize)
        let n = min(block.count, fftSize)
        for i in 0..<n { x[i] = block[i] * window[i] }
        let (re, im) = fft.forward(x)
        let half = fftSize / 2
        // 창 보정: Hann의 코히어런트 게인 0.5
        let norm = 2.0 / (Double(fftSize) * 0.5)
        var lin = [Double](repeating: Decibel.floor, count: half + 1)
        for k in 0...half { lin[k] = Decibel.fromAmplitude(ComplexMath.magnitude(re[k], im[k]) * norm) }
        let spectrum = LinearSpectrum(sampleRate: sampleRate, fftSize: fftSize, magnitudesDB: lin)
        var mags = grid.map { spectrum.magnitudeDB(at: $0) }
        if averaging > 0, let prev = averaged, prev.count == mags.count {
            for i in 0..<mags.count {
                let p = Decibel.toPower(prev[i]) * averaging + Decibel.toPower(mags[i]) * (1 - averaging)
                mags[i] = Decibel.fromPower(p)
            }
        }
        averaged = mags
        return SpectrumFrame(timestamp: Date(), frequencies: grid, magnitudesDB: mags, linear: spectrum)
    }
}

/// RTA 한 프레임. 하울링 검출기는 linear 스펙트럼(고해상도)으로 피크 주파수를 정밀하게 잡는다.
public struct SpectrumFrame: Sendable {
    public var timestamp: Date
    public var frequencies: [Double]
    public var magnitudesDB: [Double]
    public var linear: LinearSpectrum?

    public init(timestamp: Date = Date(), frequencies: [Double], magnitudesDB: [Double], linear: LinearSpectrum? = nil) {
        self.timestamp = timestamp
        self.frequencies = frequencies
        self.magnitudesDB = magnitudesDB
        self.linear = linear
    }

    public var response: FrequencyResponse { FrequencyResponse(frequencies: frequencies, magnitudesDB: magnitudesDB) }
}
