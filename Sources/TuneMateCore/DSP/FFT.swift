import Foundation
import Accelerate

/// 2의 거듭제곱 크기 복소 FFT 래퍼 (vDSP, Double 정밀도).
/// 실수 입력을 복소수로 올려 전체 스펙트럼(길이 n)을 돌려준다. 단순성을 우선한 구현이다.
public final class FFT {
    public let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetupD

    public init(size: Int) {
        precondition(size > 0 && (size & (size - 1)) == 0, "FFT size must be a power of two")
        self.size = size
        self.log2n = vDSP_Length(log2(Double(size)))
        guard let s = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetupD failed")
        }
        self.setup = s
    }

    deinit { vDSP_destroy_fftsetupD(setup) }

    public static func nextPowerOfTwo(_ n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }

    /// 실수 신호 → 복소 스펙트럼 (re, im), 길이 size. 입력이 짧으면 0으로 채운다.
    public func forward(_ x: [Double]) -> (re: [Double], im: [Double]) {
        var re = [Double](repeating: 0, count: size)
        var im = [Double](repeating: 0, count: size)
        let n = min(x.count, size)
        for i in 0..<n { re[i] = x[i] }
        transform(re: &re, im: &im, direction: FFTDirection(kFFTDirection_Forward))
        return (re, im)
    }

    /// 복소 스펙트럼 → 실수 신호(실수부). 1/size 스케일을 적용한다.
    public func inverse(re: [Double], im: [Double]) -> [Double] {
        var r = re, i = im
        transform(re: &r, im: &i, direction: FFTDirection(kFFTDirection_Inverse))
        var scale = 1.0 / Double(size)
        var out = [Double](repeating: 0, count: size)
        vDSP_vsmulD(r, 1, &scale, &out, 1, vDSP_Length(size))
        return out
    }

    private func transform(re: inout [Double], im: inout [Double], direction: FFTDirection) {
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zipD(setup, &split, 1, log2n, direction)
            }
        }
    }
}

public enum ComplexMath {
    /// a * conj(b)
    @inline(__always)
    public static func mulConj(_ ar: Double, _ ai: Double, _ br: Double, _ bi: Double) -> (Double, Double) {
        (ar * br + ai * bi, ai * br - ar * bi)
    }
    @inline(__always)
    public static func mul(_ ar: Double, _ ai: Double, _ br: Double, _ bi: Double) -> (Double, Double) {
        (ar * br - ai * bi, ar * bi + ai * br)
    }
    @inline(__always)
    public static func magnitude(_ r: Double, _ i: Double) -> Double { (r * r + i * i).squareRoot() }
}

public enum Decibel {
    public static let floor: Double = -150
    @inline(__always) public static func fromAmplitude(_ a: Double) -> Double {
        a > 0 ? max(floor, 20 * log10(a)) : floor
    }
    @inline(__always) public static func fromPower(_ p: Double) -> Double {
        p > 0 ? max(floor, 10 * log10(p)) : floor
    }
    @inline(__always) public static func toAmplitude(_ db: Double) -> Double { pow(10, db / 20) }
    @inline(__always) public static func toPower(_ db: Double) -> Double { pow(10, db / 10) }
}
