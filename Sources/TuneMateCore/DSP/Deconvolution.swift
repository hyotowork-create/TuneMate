import Foundation
import Accelerate

/// 임펄스 응답 (시간 영역).
public struct ImpulseResponse: Codable, Equatable, Sendable {
    public var sampleRate: Double
    public var samples: [Double]
    /// 피크 위치 (샘플). 정렬 후에는 preRoll 위치와 같다.
    public var peakIndex: Int

    public init(sampleRate: Double, samples: [Double], peakIndex: Int) {
        self.sampleRate = sampleRate
        self.samples = samples
        self.peakIndex = peakIndex
    }

    public var peakTimeSeconds: Double { Double(peakIndex) / sampleRate }
}

public enum Deconvolution {
    public struct Options: Sendable {
        /// 스펙트럼 나눗셈 정규화 (|X|² 최대값 대비 비율).
        public var regularization: Double = 1e-6
        /// 대역 밖 응답은 0으로 두어 잡음 폭주를 막는다.
        public var bandLimit: ClosedRange<Double>? = nil
        /// 정렬 후 피크 앞에 남길 샘플 수.
        public var preRollSamples: Int = 1024
        public init() {}
    }

    /// 녹음(y)과 원본 스윕(x)에서 임펄스 응답을 구한다.
    /// 재생이 비동기여도(믹서 USB 재생 등) 상호상관 피크로 시작점을 찾으므로 크기 응답은 영향이 없다.
    public static func impulseResponse(recorded y: [Double], reference x: [Double], sampleRate: Double,
                                       options: Options = Options()) -> ImpulseResponse {
        let n = FFT.nextPowerOfTwo(max(y.count, x.count) * 2)
        let fft = FFT(size: n)
        let (yr, yi) = fft.forward(y)
        let (xr, xi) = fft.forward(x)

        var pMax = 0.0
        for k in 0..<n { pMax = max(pMax, xr[k] * xr[k] + xi[k] * xi[k]) }
        let eps = options.regularization * pMax

        var hr = [Double](repeating: 0, count: n)
        var hi = [Double](repeating: 0, count: n)
        let binHz = sampleRate / Double(n)
        for k in 0..<n {
            let f = k <= n / 2 ? Double(k) * binHz : Double(n - k) * binHz
            if let band = options.bandLimit, !band.contains(f) { continue }
            let denom = xr[k] * xr[k] + xi[k] * xi[k] + eps
            let (nr, ni) = ComplexMath.mulConj(yr[k], yi[k], xr[k], xi[k])
            hr[k] = nr / denom
            hi[k] = ni / denom
        }
        var h = fft.inverse(re: hr, im: hi)

        // 피크 찾기 → preRoll 만큼 앞을 남기고 원형 이동
        var peak = 0
        var peakVal = 0.0
        for i in 0..<n where abs(h[i]) > peakVal { peakVal = abs(h[i]); peak = i }
        let shift = (peak - options.preRollSamples + n) % n
        if shift != 0 {
            h = Array(h[shift...] + h[..<shift])
        }
        return ImpulseResponse(sampleRate: sampleRate, samples: h, peakIndex: options.preRollSamples)
    }

    /// 상호상관으로 지연(샘플)을 추정한다. 양수 = y가 x보다 늦다.
    public static func estimateDelay(recorded y: [Double], reference x: [Double]) -> Int {
        let n = FFT.nextPowerOfTwo(max(y.count, x.count) * 2)
        let fft = FFT(size: n)
        let (yr, yi) = fft.forward(y)
        let (xr, xi) = fft.forward(x)
        var cr = [Double](repeating: 0, count: n)
        var ci = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let (r, i) = ComplexMath.mulConj(yr[k], yi[k], xr[k], xi[k])
            cr[k] = r; ci[k] = i
        }
        let c = fft.inverse(re: cr, im: ci)
        var best = 0
        var bestVal = -Double.infinity
        for i in 0..<n where c[i] > bestVal { bestVal = c[i]; best = i }
        return best > n / 2 ? best - n : best
    }
}

/// 임펄스 응답 → 주파수 응답 (크기, dB)
public enum TransferFunction {
    public struct WindowSpec: Sendable {
        /// 피크 앞 창(초), 피크 뒤 창(초). 기본: 10 ms / 500 ms
        public var leftSeconds: Double = 0.010
        public var rightSeconds: Double = 0.500
        public init(leftSeconds: Double = 0.010, rightSeconds: Double = 0.500) {
            self.leftSeconds = leftSeconds
            self.rightSeconds = rightSeconds
        }
    }

    /// Tukey형 창을 적용해 FFT 하고 선형 주파수 격자의 크기(dB)를 돌려준다.
    public static func magnitudeSpectrum(_ ir: ImpulseResponse, window: WindowSpec = WindowSpec(),
                                         fftSize: Int? = nil) -> LinearSpectrum {
        let sr = ir.sampleRate
        let left = Int(window.leftSeconds * sr)
        let right = Int(window.rightSeconds * sr)
        let start = max(0, ir.peakIndex - left)
        let end = min(ir.samples.count, ir.peakIndex + right)
        var seg = Array(ir.samples[start..<end])
        // 양끝 반 코사인 페이드
        // 페이드인은 피크 앞 구간 안에서만 (피크를 깎지 않도록)
        let prePeak = ir.peakIndex - start
        let fadeL = max(1, min(left, prePeak, seg.count / 4))
        let fadeR = max(1, min(right / 4, seg.count / 4))
        for i in 0..<fadeL { seg[i] *= 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fadeL)) }
        for i in 0..<fadeR { seg[seg.count - 1 - i] *= 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fadeR)) }

        let n = fftSize ?? FFT.nextPowerOfTwo(max(seg.count, 4096))
        let fft = FFT(size: n)
        let (re, im) = fft.forward(seg)
        let half = n / 2
        var mags = [Double](repeating: 0, count: half + 1)
        for k in 0...half { mags[k] = Decibel.fromAmplitude(ComplexMath.magnitude(re[k], im[k])) }
        return LinearSpectrum(sampleRate: sr, fftSize: n, magnitudesDB: mags)
    }
}

/// 선형 주파수 격자의 스펙트럼 (0 ... fs/2).
public struct LinearSpectrum: Codable, Equatable, Sendable {
    public var sampleRate: Double
    public var fftSize: Int
    public var magnitudesDB: [Double]

    public init(sampleRate: Double, fftSize: Int, magnitudesDB: [Double]) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.magnitudesDB = magnitudesDB
    }

    public var binWidthHz: Double { sampleRate / Double(fftSize) }
    public func frequency(ofBin k: Int) -> Double { Double(k) * binWidthHz }

    /// 선형 보간으로 임의 주파수의 dB를 구한다.
    public func magnitudeDB(at hz: Double) -> Double {
        let pos = hz / binWidthHz
        if pos <= 0 { return magnitudesDB.first ?? Decibel.floor }
        let i = Int(pos)
        if i >= magnitudesDB.count - 1 { return magnitudesDB.last ?? Decibel.floor }
        let frac = pos - Double(i)
        return magnitudesDB[i] * (1 - frac) + magnitudesDB[i + 1] * frac
    }
}
