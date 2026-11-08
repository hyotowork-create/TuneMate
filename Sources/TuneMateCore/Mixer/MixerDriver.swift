import Foundation

public enum MixerError: Error, Equatable, CustomStringConvertible {
    case notConnected
    case unsupported(String)
    case protocolUnverified(String)
    case firmwareMismatch(expected: String, actual: String)
    case invalidTarget(EQTarget)
    case transport(String)
    case timeout

    public var description: String {
        switch self {
        case .notConnected: return "믹서가 연결되지 않았습니다."
        case .unsupported(let s): return "지원하지 않는 기능: \(s)"
        case .protocolUnverified(let s): return "프로토콜 미검증 — 쓰기 차단: \(s)"
        case .firmwareMismatch(let e, let a): return "펌웨어 불일치 (명세 \(e), 믹서 \(a)) — 쓰기 차단"
        case .invalidTarget(let t): return "잘못된 대상: \(t)"
        case .transport(let s): return "통신 오류: \(s)"
        case .timeout: return "응답 시간 초과"
        }
    }
}

public enum ConnectionStatus: Equatable, Sendable {
    case disconnected, connecting, connected, failed(String)
}

/// 모든 믹서 드라이버의 공통 인터페이스. 기획서 6장 DM24Kit 인터페이스를 일반화했다.
/// dB 단위로 받고, 인코딩은 드라이버 내부에서 처리한다.
public protocol MixerDriver: AnyObject, Sendable {
    var model: MixerModel { get }
    var status: ConnectionStatus { get async }

    func connect(host: String) async throws
    func disconnect() async

    /// 전 채널·출력 파라미터
    func snapshot() async throws -> MixerState
    /// 미터 스트림 (지원하지 않으면 nil)
    func meters() async -> AsyncStream<Levels>?

    func setFader(_ target: EQTarget, dB: Double) async throws
    func setMute(_ target: EQTarget, on: Bool) async throws
    func setPreampGain(channel: Int, dB: Double) async throws
    func setPan(channel: Int, pan: Double) async throws
    func setEQBand(_ target: EQTarget, band: Int, frequencyHz: Double, gainDB: Double, q: Double, on: Bool) async throws
    func setEQEnabled(_ target: EQTarget, on: Bool) async throws
    func setAuxSend(channel: Int, aux: Int, dB: Double) async throws
    func setDelay(output: EQTarget, ms: Double) async throws
    func setPhantom(channel: Int, on: Bool) async throws
    func saveScene(number: Int, name: String) async throws
    func recallScene(number: Int) async throws
}

public extension MixerDriver {
    /// 스냅샷 전체를 믹서에 다시 쓴다 (되돌리기용). 씬 저장이 없는 믹서를 위한 기본 구현.
    func restore(_ state: MixerState) async throws {
        for c in state.channels {
            try await setFader(.channel(c.index), dB: c.faderDB)
            try await setMute(.channel(c.index), on: c.muted)
            for b in c.eq { try await setEQBand(.channel(c.index), band: b.index, frequencyHz: b.frequencyHz, gainDB: b.gainDB, q: b.q, on: b.enabled) }
            for (i, s) in c.auxSendsDB.enumerated() { try await setAuxSend(channel: c.index, aux: i + 1, dB: s) }
        }
        for o in state.outputs {
            try await setFader(o.target, dB: o.faderDB)
            try await setMute(o.target, on: o.muted)
            for b in o.eq { try await setEQBand(o.target, band: b.index, frequencyHz: b.frequencyHz, gainDB: b.gainDB, q: b.q, on: b.enabled) }
        }
    }
}
