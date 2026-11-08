import Foundation

/// RBJ 바이쿼드 (디지털 IIR). 시뮬레이션·필터 응답 검증용.
public struct Biquad: Sendable, Equatable {
    public var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    public static func peaking(fs: Double, f0: Double, gainDB: Double, q: Double) -> Biquad {
        let A = pow(10, gainDB / 40), w0 = 2 * Double.pi * f0 / fs, alpha = sin(w0) / (2 * q), c = cos(w0)
        let a0 = 1 + alpha / A
        return Biquad(b0: (1 + alpha * A) / a0, b1: -2 * c / a0, b2: (1 - alpha * A) / a0, a1: -2 * c / a0, a2: (1 - alpha / A) / a0)
    }
    public static func highShelf(fs: Double, f0: Double, gainDB: Double, q: Double = 0.707) -> Biquad {
        let A = pow(10, gainDB / 40), w0 = 2 * Double.pi * f0 / fs, alpha = sin(w0) / (2 * q), c = cos(w0)
        let sA = 2 * A.squareRoot() * alpha
        let a0 = (A + 1) - (A - 1) * c + sA
        return Biquad(b0: A * ((A + 1) + (A - 1) * c + sA) / a0, b1: -2 * A * ((A - 1) + (A + 1) * c) / a0, b2: A * ((A + 1) + (A - 1) * c - sA) / a0,
                      a1: 2 * ((A - 1) - (A + 1) * c) / a0, a2: ((A + 1) - (A - 1) * c - sA) / a0)
    }
    public static func lowShelf(fs: Double, f0: Double, gainDB: Double, q: Double = 0.707) -> Biquad {
        let A = pow(10, gainDB / 40), w0 = 2 * Double.pi * f0 / fs, alpha = sin(w0) / (2 * q), c = cos(w0)
        let sA = 2 * A.squareRoot() * alpha
        let a0 = (A + 1) + (A - 1) * c + sA
        return Biquad(b0: A * ((A + 1) - (A - 1) * c + sA) / a0, b1: 2 * A * ((A - 1) - (A + 1) * c) / a0, b2: A * ((A + 1) - (A - 1) * c - sA) / a0,
                      a1: -2 * ((A - 1) + (A + 1) * c) / a0, a2: ((A + 1) + (A - 1) * c - sA) / a0)
    }

    public func magnitudeDB(at f: Double, fs: Double) -> Double {
        let w = 2 * Double.pi * f / fs
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return Decibel.fromAmplitude((nr * nr + ni * ni).squareRoot() / (dr * dr + di * di).squareRoot())
    }

    public func process(_ x: [Double]) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let v = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x[i]; y2 = y1; y1 = v
            y[i] = v
        }
        return y
    }
}
