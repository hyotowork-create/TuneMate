import Foundation

/// 운영 모드 (기획서 7장).
public enum OperatingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case proposal        // 제안 모드(기본): 사람이 적용 버튼
    case rehearsalAuto   // 리허설 자동: 한도 안은 바로 적용
    case serviceLock     // 예배 잠금: 읽기 전용

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .proposal: return "제안 모드"
        case .rehearsalAuto: return "리허설 자동 모드"
        case .serviceLock: return "예배 잠금 모드"
        }
    }
    public var explanation: String {
        switch self {
        case .proposal: return "AI가 변경안을 보여 주고, 사람이 적용 버튼을 누릅니다."
        case .rehearsalAuto: return "한도 안의 변경은 바로 적용하고, 한도 밖은 승인을 요청합니다. 예배 전 리허설용."
        case .serviceLock: return "읽기 전용. 진단과 제안만 하고 믹서를 바꾸지 않습니다. 예배 중."
        }
    }
}

/// 한도 설정 (기획서 7장 안전장치). 모두 설정에서 바꿀 수 있다.
public struct SafetyPolicy: Codable, Equatable, Sendable {
    /// 한 번에 올릴 수 있는 폭(dB) — 페이더·센드·EQ 부스트 공통
    public var maxIncreaseStepDB: Double = 3
    /// 한 번에 내릴 수 있는 폭(dB) — 실수로 소리를 죽이지 않도록
    public var maxDecreaseStepDB: Double = 12
    /// 메인 출력 상한 (dB)
    public var mainOutputCapDB: Double = 0
    /// 한 변경안에서 뮤트할 수 있는 채널 수
    public var maxMutesPerProposal: Int = 2
    /// EQ 밴드 게인 절대값 한도
    public var maxEQGainAbsDB: Double = 12
    /// 노치 한도 (하울링)
    public var notch: NotchPolicy = NotchPolicy()
    /// 미검증 프로토콜 믹서에는 어떤 모드에서도 쓰지 않는다
    public var blockWritesToUnverifiedProtocol: Bool = true

    public init() {}
}
