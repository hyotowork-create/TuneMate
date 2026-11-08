import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CoreAudio) && os(macOS)
import CoreAudio
#endif

public enum MicrophoneKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case umik1, builtIn, simulated
    public var id: String { rawValue }
    public var displayName: String {
        switch self { case .umik1: return "UMIK-1 측정마이크"; case .builtIn: return "내장 마이크 (하울링 검출 보조만)"; case .simulated: return "시뮬레이션 (장비 없음)" }
    }
}

public enum AudioEngineError: Error, CustomStringConvertible {
    case noInput, formatMismatch(String), timeout, unavailable(String), permissionDenied
    public var description: String {
        switch self {
        case .noInput: return "오디오 입력 장치가 없습니다. UMIK-1을 연결했는지 확인하세요."
        case .formatMismatch(let s): return "오디오 형식 문제: \(s)"
        case .timeout: return "녹음이 끝나지 않았습니다 (시간 초과)."
        case .unavailable(let s): return "오디오 엔진을 쓸 수 없습니다: \(s)"
        case .permissionDenied: return "마이크 사용 권한이 없습니다. 시스템 설정 → 개인정보 보호 → 마이크에서 튠메이트를 허용하세요."
        }
    }
}

public struct AudioDeviceInfo: Sendable, Equatable {
    public var inputName: String
    public var inputSampleRate: Double
    public var inputChannels: Int
    public var looksLikeUMIK: Bool { inputName.uppercased().contains("UMIK") }
}

#if canImport(AVFoundation)
/// AVAudioEngine 기반 측정 입출력. 재생(스윕) + 동시 녹음, 그리고 RTA용 입력 탭.
public final class MeasurementAudioEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var recordBuffer: [Double] = []
    private var recording = false
    private var monitorHandler: (([Double], Double) -> Void)?
    private var tapInstalled = false

    public init() {}

    /// 입력 장치를 고른다. macOS 는 CoreAudio 장치 ID, iOS 는 AVAudioSession 포트 UID.
    public func selectInput(_ device: AudioInputDevice) throws {
        #if os(macOS)
        guard let id = AudioDeviceID(device.id), let unit = engine.inputNode.audioUnit else { throw AudioEngineError.unavailable("입력 유닛 없음") }
        var devID = id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw AudioEngineError.unavailable("장치 전환 실패 (\(status))") }
        #elseif os(iOS)
        let session = AVAudioSession.sharedInstance()
        if let port = session.availableInputs?.first(where: { $0.uid == device.id }) { try session.setPreferredInput(port) }
        #endif
    }

    /// 입력 장치 정보 (측정 모드 세션 설정 포함)
    /// 마이크 권한 요청 (앱 첫 측정 전에 한 번).
    public static func requestPermission() async -> Bool {
        if #available(macOS 14, iOS 17, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return true
    }

    public func prepare() throws -> AudioDeviceInfo {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true)
        let name = session.currentRoute.inputs.first?.portName ?? "입력 없음"
        #else
        let name = Self.defaultInputDeviceName() ?? "기본 입력"
        #endif
        let fmt = engine.inputNode.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw AudioEngineError.noInput }
        return AudioDeviceInfo(inputName: name, inputSampleRate: fmt.sampleRate, inputChannels: Int(fmt.channelCount))
    }

    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buffer, _ in
            guard let self, let ch = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            var mono = [Double](repeating: 0, count: n)
            let chans = Int(buffer.format.channelCount)
            // 첫 채널만 사용 (UMIK-1 은 모노)
            for i in 0..<n { mono[i] = Double(ch[0][i]) }
            _ = chans
            self.lock.lock()
            if self.recording { self.recordBuffer.append(contentsOf: mono) }
            let handler = self.monitorHandler
            self.lock.unlock()
            handler?(mono, buffer.format.sampleRate)
        }
        tapInstalled = true
    }

    private func startEngine() throws {
        if !engine.isRunning {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: nil)
            installTapIfNeeded()
            engine.prepare()
            try engine.start()
        }
    }

    public func stop() {
        player.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
        lock.withLock { monitorHandler = nil; recording = false }
    }

    /// 스윕을 재생하면서 녹음한다. 반환: (녹음 샘플, 샘플레이트, 실제 사용한 스윕 스펙)
    /// 하드웨어 샘플레이트가 다르면 그 레이트로 스윕을 다시 만든다.
    public func runSweep(_ requested: SweepSpec, playThroughOutput: Bool = true) async throws -> (recorded: [Double], spec: SweepSpec) {
        try startEngine()
        let inFmt = engine.inputNode.inputFormat(forBus: 0)
        var spec = requested
        spec.sampleRate = inFmt.sampleRate
        let signal = SweepGenerator.playbackSignal(spec)
        let outFmt = AVAudioFormat(standardFormatWithSampleRate: spec.sampleRate, channels: 2)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(signal.count)) else { throw AudioEngineError.formatMismatch("buffer") }
        buf.frameLength = AVAudioFrameCount(signal.count)
        if let ch = buf.floatChannelData {
            for i in 0..<signal.count { ch[0][i] = Float(signal[i]); ch[1][i] = Float(signal[i]) }
        }
        lock.withLock { recordBuffer.removeAll(keepingCapacity: true); recordBuffer.reserveCapacity(signal.count + Int(spec.sampleRate)); recording = true }
        if playThroughOutput { schedule(buf) }
        let needed = signal.count + Int(0.5 * spec.sampleRate)
        let deadline = Date().addingTimeInterval(Double(needed) / spec.sampleRate + 5)
        while true {
            try await Task.sleep(nanoseconds: 100_000_000)
            let count = lock.withLock { recordBuffer.count }
            if count >= needed { break }
            if Date() > deadline { lock.withLock { recording = false }; throw AudioEngineError.timeout }
        }
        let out: [Double] = lock.withLock { recording = false; return recordBuffer }
        player.stop()
        return (out, spec)
    }

    private func schedule(_ buf: AVAudioPCMBuffer) {
        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        player.play()
    }

    /// RTA/하울링용 실시간 입력. handler(samples, sampleRate)
    public func startMonitoring(_ handler: @escaping ([Double], Double) -> Void) throws {
        try startEngine()
        lock.withLock { monitorHandler = handler }
    }
    public func stopMonitoring() { lock.withLock { monitorHandler = nil } }

    /// 핑크노이즈 재생 (RTA 확인용). 반복 재생.
    public func playPinkNoise(seconds: Double = 20, amplitude: Double = 0.2) throws {
        try startEngine()
        let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sig = SweepGenerator.pinkNoise(sampleCount: Int(seconds * sr), amplitude: amplitude)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sig.count)) else { return }
        buf.frameLength = AVAudioFrameCount(sig.count)
        if let ch = buf.floatChannelData { for i in 0..<sig.count { ch[0][i] = Float(sig[i]); ch[1][i] = Float(sig[i]) } }
        player.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
        player.play()
    }
    public func stopPlayback() { player.stop() }

    #if os(macOS)
    static func defaultInputDeviceName() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr, deviceID != 0 else { return nil }
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfName: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &cfName) == noErr, let n = cfName?.takeRetainedValue() else { return nil }
        return n as String
    }
    #endif
}
#endif

/// WAV 파일 쓰기 (16/24-bit PCM). 믹서 USB 재생용 스윕 파일 내보내기.
public enum WAVWriter {
    public static func data(samples: [Double], sampleRate: Double, bitsPerSample: Int = 24, channels: Int = 1) -> Data {
        let bytesPerSample = bitsPerSample / 8
        let dataSize = samples.count * channels * bytesPerSample
        var d = Data(capacity: 44 + dataSize)
        func u32(_ v: UInt32) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }
        func u16(_ v: UInt16) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataSize)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(Int(sampleRate) * channels * bytesPerSample)); u16(UInt16(channels * bytesPerSample)); u16(UInt16(bitsPerSample))
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataSize))
        let maxV = Double((1 << (bitsPerSample - 1)) - 1)
        for s in samples {
            let v = Int32(max(-maxV, min(maxV, s * maxV)).rounded())
            for _ in 0..<channels {
                if bitsPerSample == 16 { u16(UInt16(bitPattern: Int16(v))) }
                else { d.append(contentsOf: [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16)]) }
            }
        }
        return d
    }

    public static func write(samples: [Double], sampleRate: Double, to url: URL, bitsPerSample: Int = 24) throws {
        try data(samples: samples, sampleRate: sampleRate, bitsPerSample: bitsPerSample).write(to: url, options: .atomic)
    }
}

/// 장비 없이 전체 흐름을 돌려 보는 가상 예배당. 인과적(IIR) 필터 체인이라 실제 방처럼 최소위상에 가깝다.
/// 좌석 위치마다 모드 주파수·고역 기울기가 조금씩 다르다.
public struct SimulatedRoom: Sendable {
    public struct Mode: Sendable, Equatable { public var type: EQFilterType; public var hz: Double; public var gainDB: Double; public var q: Double
        public init(type: EQFilterType = .peaking, hz: Double, gainDB: Double, q: Double) { self.type = type; self.hz = hz; self.gainDB = gainDB; self.q = q } }
    public var seed: UInt64
    public var modes: [Mode]
    public var delaySamples: Int
    public var noiseAmplitude: Double
    public var sampleRate: Double

    public init(seed: UInt64 = 1, modes: [Mode]? = nil, delaySamples: Int = 2_400, noiseAmplitude: Double = 0.0005, sampleRate: Double = 48_000) {
        self.seed = seed
        self.modes = modes ?? [
            Mode(hz: 63, gainDB: 7, q: 3),          // 저역 정재파
            Mode(hz: 125, gainDB: 4, q: 2.5),
            Mode(hz: 180, gainDB: -14, q: 4),       // 깊은 딥 (방 구조)
            Mode(hz: 2_500, gainDB: 3.5, q: 1.5),   // 혼 공진
            Mode(hz: 6_300, gainDB: -3, q: 1.2),
            Mode(type: .highShelf, hz: 8_000, gainDB: -4, q: 0.7)
        ]
        self.delaySamples = delaySamples
        self.noiseAmplitude = noiseAmplitude
        self.sampleRate = sampleRate
    }

    func chain(position: Int) -> [Biquad] {
        var rng = SplitMix64(seed: seed &+ UInt64(position) &* 7919)
        let shift = 1 + (rng.nextUniform() - 0.5) * 0.12       // 위치별 모드 주파수 ±6%
        let tilt = (rng.nextUniform() - 0.5) * 2.0             // 위치별 고역 기울기 ±1 dB
        var out = modes.map { m -> Biquad in
            switch m.type {
            case .highShelf: return Biquad.highShelf(fs: sampleRate, f0: m.hz * shift, gainDB: m.gainDB, q: m.q)
            case .lowShelf: return Biquad.lowShelf(fs: sampleRate, f0: m.hz * shift, gainDB: m.gainDB, q: m.q)
            default: return Biquad.peaking(fs: sampleRate, f0: m.hz * shift, gainDB: m.gainDB + (rng.nextUniform() - 0.5), q: m.q)
            }
        }
        out.append(Biquad.highShelf(fs: sampleRate, f0: 3_000, gainDB: tilt, q: 0.5))
        return out
    }

    /// 위치별 '참' 응답 (dB, 70 dB 기준 레벨)
    public func trueResponse(position: Int, grid: [Double] = FrequencyResponse.logGrid()) -> FrequencyResponse {
        let c = chain(position: position)
        return FrequencyResponse(frequencies: grid, magnitudesDB: grid.map { f in 70 + c.reduce(0) { $0 + $1.magnitudeDB(at: f, fs: sampleRate) } })
    }

    /// 스윕을 이 방에 재생해 녹음한 결과를 흉내낸다 (IIR 체인 + 지연 + 잡음).
    public func simulateRecording(spec: SweepSpec, position: Int) -> [Double] {
        var y = [Double](repeating: 0, count: delaySamples) + SweepGenerator.sweep(spec) + [Double](repeating: 0, count: Int(spec.sampleRate))
        for b in chain(position: position) { y = b.process(y) }
        var rng = SplitMix64(seed: seed &+ 99)
        for i in 0..<y.count { y[i] = y[i] * 0.3 + noiseAmplitude * (rng.nextUniform() * 2 - 1) }
        return y
    }
}
