import Foundation

/// 사람이 공식 앱(콘솔 아이패드)에서 직접 입력할 수정 지시. 기기 간 전송·음성 읽기·체크리스트에 쓴다.
public struct Instruction: Codable, Equatable, Sendable, Identifiable {
    public struct Step: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID = UUID()
        public var text: String
        public var done: Bool = false
        public init(text: String) { self.text = text }
    }
    public var id: UUID = UUID()
    public var createdAt: Date = Date()
    public var from: String            // 보낸 기기 이름
    public var title: String
    public var rationale: String
    public var steps: [Step]
    public var acknowledgedAt: Date? = nil

    public init(from: String, title: String, rationale: String, steps: [String]) {
        self.from = from; self.title = title; self.rationale = rationale; self.steps = steps.map(Step.init)
    }

    /// 변경안 → 지시 (현재값 → 제안값 문장 그대로)
    public static func from(proposal: ChangeProposal, state: MixerState?, sender: String) -> Instruction {
        let resolved = proposal.resolved.isEmpty && state != nil ? ChangeResolver.resolve(proposal.changes, against: state!) : proposal.resolved
        let steps = resolved.isEmpty ? proposal.changes.map { describe($0) } : resolved.map(\.summary)
        return Instruction(from: sender, title: proposal.source == .autoEQ ? "공간 보정 EQ 입력" : (proposal.source == .feedbackSuppressor ? "하울링 노치 입력" : "믹서 조정"),
                           rationale: proposal.rationale, steps: steps)
    }

    /// 보정표 → 지시
    public static func from(assignments: [EQAssignment], sender: String) -> Instruction {
        Instruction(from: sender, title: "메인 출력 EQ 입력 (\(assignments.count)밴드)", rationale: "공간 측정 보정값. 입력 후 같은 위치에서 재측정.",
                    steps: assignments.map { String(format: "%@ %d밴드: %.0f Hz, %+.1f dB, Q %.1f, PEQ 켬", $0.target, $0.band, $0.frequencyHz, $0.gainDB, $0.q) })
    }

    static func describe(_ c: MixerChange) -> String {
        switch c {
        case .faderRelative(let t, let d): return String(format: "%@ 페이더 %+.1f dB", t.description, d)
        case .faderAbsolute(let t, let v): return String(format: "%@ 페이더를 %.1f dB 로", t.description, v)
        case .mute(let t, let on): return "\(t) 뮤트 \(on ? "켬" : "끔")"
        case .eqBand(let t, let b, let f, let g, let q, let on): return String(format: "%@ EQ %d밴드: %.0f Hz, %+.1f dB, Q %.1f%@", t.description, b, f, g, q, on ? "" : " (끔)")
        case .eqEnabled(let t, let on): return "\(t) EQ \(on ? "켬" : "끔")"
        case .auxSendRelative(let ch, let aux, let d): return String(format: "CH%d → AUX%d 센드 %+.1f dB", ch, aux, d)
        case .auxSendAbsolute(let ch, let aux, let v): return String(format: "CH%d → AUX%d 센드를 %.1f dB 로", ch, aux, v)
        case .preampGain(let ch, let v): return String(format: "CH%d 프리앰프 게인을 %.0f dB 로", ch, v)
        case .pan(let ch, let p): return String(format: "CH%d 팬 %.2f", ch, p)
        case .delay(let o, let ms): return String(format: "%@ 딜레이 %.1f ms", o.description, ms)
        case .phantom(let ch, let on): return "CH\(ch) 팬텀 +48V \(on ? "켬" : "끔")"
        case .sceneRecall(let n): return "씬 \(n) 불러오기"
        case .routing(let d): return "라우팅: \(d)"
        }
    }

    /// 음성으로 읽을 문장
    public var spokenText: String {
        var s = "\(title). "
        for (i, st) in steps.enumerated() { s += "\(i + 1)번. \(st.text.replacingOccurrences(of: "→", with: "에서").replacingOccurrences(of: "dB", with: "데시벨").replacingOccurrences(of: "Hz", with: "헤르츠")). " }
        return s
    }
}

/// 믹서에 연결된 기기(콘솔)가 다른 기기에 알리는 상태.
public struct ConsoleStatus: Codable, Equatable, Sendable {
    public var deviceName: String
    public var connected: Bool
    public var model: MixerModel
    public var mode: OperatingMode
    public var state: MixerState?
    public var acceptsRemoteProposals: Bool
    public var sentAt: Date = Date()
    public init(deviceName: String, connected: Bool, model: MixerModel, mode: OperatingMode, state: MixerState?, acceptsRemoteProposals: Bool) {
        self.deviceName = deviceName; self.connected = connected; self.model = model; self.mode = mode; self.state = state; self.acceptsRemoteProposals = acceptsRemoteProposals
    }
}

/// 원격 적용 요청의 결과.
public struct RemoteOutcome: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case applied, denied, rejectedByUser, error }
    public var requestID: UUID
    public var kind: Kind
    public var summaries: [String]
    public var reasons: [String]
    public var by: String
    public init(requestID: UUID, kind: Kind, summaries: [String], reasons: [String], by: String) {
        self.requestID = requestID; self.kind = kind; self.summaries = summaries; self.reasons = reasons; self.by = by
    }
}

/// 기기 간 메시지
public enum PeerMessage: Codable, Equatable, Sendable {
    case hello(deviceName: String, role: String)
    case instruction(Instruction)
    case acknowledged(id: UUID, by: String)
    /// 변경안 원격 적용 요청 (콘솔 기기가 안전 계층·승인을 거쳐 적용)
    case proposal(requestID: UUID, proposal: ChangeProposal)
    case outcome(RemoteOutcome)
    /// 콘솔 상태 알림 (연결·모드·믹서 상태)
    case console(ConsoleStatus)
    /// 측정 세션 공유 (보정 결과 포함)
    case measurement(MeasurementSession)
    /// 공간·채널 이름표 공유
    case venue(VenueProfile)
    /// 하울링 후보 공유 (감시 중인 기기 → 다른 기기)
    case feedback([FeedbackCandidate], from: String)
}
