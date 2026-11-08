import Testing
import Foundation
@testable import TuneMateCore

/// 간단한 1차 IIR 로우패스(테스트용 "방"): y[n] = (1-a) x[n] + a y[n-1]
private func lowpass(_ x: [Double], a: Double) -> [Double] {
    var y = [Double](repeating: 0, count: x.count)
    var prev = 0.0
    for i in 0..<x.count { prev = (1 - a) * x[i] + a * prev; y[i] = prev }
    return y
}

private func lowpassMagnitudeDB(_ f: Double, a: Double, sr: Double) -> Double {
    // H(z) = (1-a) / (1 - a z^-1)
    let w = 2 * Double.pi * f / sr
    let re = 1 - a * cos(w), im = a * sin(w)
    return 20 * log10((1 - a) / (re * re + im * im).squareRoot())
}

@Suite("DSP")
struct DSPTests {
    @Test func fftRoundTrip() {
        let fft = FFT(size: 1024)
        var x = [Double](repeating: 0, count: 1024)
        for i in 0..<1024 { x[i] = sin(Double(i) * 0.1) + 0.3 * cos(Double(i) * 0.37) }
        let (re, im) = fft.forward(x)
        let y = fft.inverse(re: re, im: im)
        for i in 0..<1024 { #expect(abs(x[i] - y[i]) < 1e-9) }
    }

    @Test func sweepHasExpectedLengthAndAmplitude() {
        let spec = SweepSpec(sampleRate: 48_000, durationSeconds: 2, amplitude: 0.5)
        let s = SweepGenerator.sweep(spec)
        #expect(s.count == 96_000)
        #expect((s.map { abs($0) }.max() ?? 0) <= 0.5 + 1e-12)
        #expect((s.map { abs($0) }.max() ?? 0) > 0.49)
    }

    @Test func deconvolutionRecoversKnownFilterWithDelay() {
        let sr = 48_000.0
        let spec = SweepSpec(sampleRate: sr, startHz: 20, endHz: 20_000, durationSeconds: 3, leadInSeconds: 0, tailSeconds: 0.5)
        let x = SweepGenerator.sweep(spec)
        let a = 0.9
        // 임의 지연 1234 샘플 + 로우패스 + 뒤쪽 여유
        var y = [Double](repeating: 0, count: 1234) + x + [Double](repeating: 0, count: 24_000)
        y = lowpass(y, a: a)
        var opt = Deconvolution.Options()
        opt.bandLimit = 15...20_000
        let ir = Deconvolution.impulseResponse(recorded: y, reference: x, sampleRate: sr, options: opt)
        #expect(ir.peakIndex == opt.preRollSamples)
        let spectrum = TransferFunction.magnitudeSpectrum(ir)
        let resp = FrequencyResponse.fromLinear(spectrum)
        // 100 Hz ~ 10 kHz 에서 이론값과 0.5 dB 이내
        var maxErr = 0.0
        for (f, m) in zip(resp.frequencies, resp.magnitudesDB) where f >= 100 && f <= 10_000 {
            maxErr = max(maxErr, abs(m - lowpassMagnitudeDB(f, a: a, sr: sr)))
        }
        #expect(maxErr < 0.5, "max error \(maxErr) dB")
    }

    @Test func delayEstimation() {
        let spec = SweepSpec(sampleRate: 48_000, durationSeconds: 1, leadInSeconds: 0, tailSeconds: 0)
        let x = SweepGenerator.sweep(spec)
        let y = [Double](repeating: 0, count: 777) + x
        #expect(Deconvolution.estimateDelay(recorded: y, reference: x) == 777)
    }

    @Test func smoothingKeepsFlatAndReducesSpike() {
        let grid = FrequencyResponse.logGrid(pointsPerOctave: 48)
        var mags = [Double](repeating: 0, count: grid.count)
        let flat = FrequencyResponse(frequencies: grid, magnitudesDB: mags).smoothed(fractionOfOctave: 6)
        #expect(flat.magnitudesDB.allSatisfy { abs($0) < 1e-9 })
        mags[grid.count / 2] = 20
        let spiky = FrequencyResponse(frequencies: grid, magnitudesDB: mags).smoothed(fractionOfOctave: 6)
        #expect(spiky.magnitudesDB[grid.count / 2] < 12)
        #expect(spiky.magnitudesDB[grid.count / 2] > 0)
    }

    @Test func spatialAverageIsPowerMean() {
        let grid = FrequencyResponse.logGrid(pointsPerOctave: 12)
        let a = FrequencyResponse(frequencies: grid, magnitudesDB: grid.map { _ in 0 })
        let b = FrequencyResponse(frequencies: grid, magnitudesDB: grid.map { _ in 10 })
        let avg = FrequencyResponse.spatialAverage([a, b])!
        // 10log10((1+10)/2) = 7.40
        #expect(abs(avg.magnitudesDB[0] - 7.4036) < 0.01)
    }

    @Test func calibrationParsing() throws {
        let text = """
        "Sens Factor =-18.5dB, SERNO: 7001234"
        10.0\t-2.1\t0
        20.0\t-1.0
        100.0\t0.0
        1000.0\t0.2
        10000.0\t1.5
        20000.0\t3.0
        """
        let cal = try MicrophoneCalibration.parse(text)
        #expect(cal.serialNumber == "7001234")
        #expect(cal.sensitivityFactorDB == -18.5)
        #expect(cal.frequencies.count == 6)
        #expect(abs(cal.gainDB(at: 100) - 0.0) < 1e-9)
        // 1k~10k 로그 보간 중간(√10k ≈ 3162Hz) = 0.85
        #expect(abs(cal.gainDB(at: 3162.28) - 0.85) < 0.01)
        let grid = FrequencyResponse.logGrid(pointsPerOctave: 12)
        let r = FrequencyResponse(frequencies: grid, magnitudesDB: grid.map { _ in 0 })
        let corrected = cal.apply(to: r)
        #expect(abs(corrected.magnitudeDB(at: 3162.28) - (-0.85)) < 0.02)
    }

    @Test func rtaFindsTone() {
        let sr = 48_000.0
        let rta = RealTimeAnalyzer(sampleRate: sr, fftSize: 8192, averaging: 0)
        let f0 = 2_000.0
        let block = (0..<8192).map { 0.5 * sin(2 * Double.pi * f0 * Double($0) / sr) }
        let frame = rta.analyze(block)
        let lin = frame.linear!
        let k = Int(f0 / lin.binWidthHz)
        // 0.5 진폭 사인 → 약 -6 dBFS (창 보정 포함, ±1.5 dB)
        #expect(abs(lin.magnitudesDB[k] - (-6.02)) < 1.5)
        // 피크가 다른 곳보다 확실히 크다
        #expect(lin.magnitudesDB[k] - lin.magnitudesDB[k * 2] > 40)
    }
}
