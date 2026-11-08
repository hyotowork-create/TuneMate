import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if os(macOS)
import CoreAudio
#endif

/// 오디오 입력 장치 한 개.
public struct AudioInputDevice: Identifiable, Equatable, Sendable {
    public var id: String          // macOS: AudioDeviceID 문자열, iOS: portType+uid
    public var name: String
    public var sampleRate: Double
    public var channels: Int
    public var isDefault: Bool
    public var looksLikeUMIK: Bool { name.uppercased().contains("UMIK") }
    public var kind: String {
        let n = name.uppercased()
        if n.contains("UMIK") { return "측정마이크" }
        if n.contains("BUILT-IN") || n.contains("내장") || n.contains("MACBOOK") || n.contains("IPHONE") || n.contains("IPAD") { return "내장" }
        return "외부"
    }
}

/// 입력 장치 나열·선택. macOS 는 CoreAudio, iOS 는 AVAudioSession.
public enum AudioDevices {
    public static func inputs() -> [AudioInputDevice] {
        #if os(macOS)
        var out: [AudioInputDevice] = []
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return out }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return out }
        let defaultID = defaultInputID()
        for id in ids {
            let ch = inputChannelCount(id)
            guard ch > 0 else { continue }
            out.append(AudioInputDevice(id: String(id), name: name(of: id) ?? "장치 \(id)", sampleRate: sampleRate(of: id), channels: ch, isDefault: id == defaultID))
        }
        return out
        #elseif os(iOS)
        let session = AVAudioSession.sharedInstance()
        let current = session.currentRoute.inputs.first?.uid
        return (session.availableInputs ?? []).map {
            AudioInputDevice(id: $0.uid, name: $0.portName, sampleRate: session.sampleRate, channels: $0.channels?.count ?? 1, isDefault: $0.uid == current)
        }
        #else
        return []
        #endif
    }

    #if os(macOS)
    static func defaultInputID() -> AudioDeviceID {
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }
    static func name(of id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }
    static func sampleRate(of id: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var sr = 0.0; var size = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &sr)
        return sr
    }
    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    #endif
}
