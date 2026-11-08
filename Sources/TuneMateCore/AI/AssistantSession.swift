import Foundation

/// 대화 맥락 (기획서 7장): 채널 이름표, 공간 정보, 최근 측정, 현재 모드를 매 요청에 함께 보낸다.
public struct VenueProfile: Codable, Equatable, Sendable {
    public var name: String = "본당"
    public var seats: Int = 150
    public var speakerLayout: String = "메인 L/R + 서브 1"
    public var channelLabels: [Int: String] = [1: "설교", 2: "사회", 5: "찬양 보컬 1", 6: "찬양 보컬 2", 9: "어쿠스틱 기타", 11: "키보드 L", 12: "키보드 R"]
    public var notes: String = ""
    public init() {}
}

public struct AssistantContext: Sendable {
    public var venue: VenueProfile
    public var mode: OperatingMode
    public var mixerModel: MixerModel
    public var measurement: MeasurementSummary?
    public init(venue: VenueProfile, mode: OperatingMode, mixerModel: MixerModel, measurement: MeasurementSummary?) {
        self.venue = venue; self.mode = mode; self.mixerModel = mixerModel; self.measurement = measurement
    }

    public func systemPrompt() -> String {
        var s = """
        당신은 교회 예배당 음향 담당자를 돕는 음향 엔지니어 어시스턴트 '튠메이트'입니다. 한국어로 짧고 결과 중심으로 답합니다.
        믹서: \(mixerModel.displayName) (채널 \(mixerModel.channelCount), AUX \(mixerModel.auxCount), 채널 EQ \(mixerModel.channelEQBands)밴드, 메인 EQ \(mixerModel.mainEQBands)밴드 \(mixerModel.mainEQKind)).
        공간: \(venue.name), 좌석 \(venue.seats), 스피커 \(venue.speakerLayout). \(venue.notes)
        채널 이름표: \(venue.channelLabels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        현재 모드: \(mode.displayName) — \(mode.explanation)

        규칙:
        - 믹서 값을 바꿀 때는 절대값이 아니라 상대값(±dB)만 제안합니다. 현재값 읽기·계산·쓰기는 앱이 합니다.
        - 변경은 먼저 propose_changes 로 변경안을 만들고, 사용자가 원하면 apply_changes 로 적용 요청합니다. 간단한 1건은 adjust_fader/adjust_send/set_eq_band 를 바로 써도 됩니다.
        - 한 번에 +3 dB 이상 올리기, 메인 출력 상한 초과, 여러 채널 뮤트, 팬텀·씬·라우팅 변경은 앱이 승인을 요구하거나 거절합니다. 거절되면 이유를 그대로 전하세요.
        - 측정 결과를 설명할 때는 원인이 스피커 문제인지 방(반사·정재파) 문제인지 구분하고, EQ로 해결되지 않는 항목(스피커 위치·각도, 반사)은 따로 짚습니다. 필터 수치 자체는 앱이 계산합니다.
        - 예배 잠금 모드에서는 진단과 제안만 합니다.
        - 모르는 값은 추측하지 말고 get_mixer_state / get_channel / get_meters 로 확인합니다.
        """
        if let m = measurement {
            s += "\n\n최근 측정 (\(m.positions)지점, \(m.microphone)): 목표 대비 편차 " + (m.bandSummary.isEmpty ? "±1.5 dB 이내" : m.bandSummary.joined(separator: ", "))
            s += String(format: "\n보정 필터 %d개 제안, 보정 전 RMS %.1f → 예상 %.1f dB.", m.proposedFilters.count, m.initialRMSDB, m.residualRMSDB)
            if !m.excludedDips.isEmpty { s += " 제외 딥: " + m.excludedDips.joined(separator: ", ") }
            if !m.feedbackCandidates.isEmpty { s += " 하울링 후보: " + m.feedbackCandidates.joined(separator: ", ") }
        }
        return s
    }
}

public struct AssistantTurn: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable { case user, assistant, tool }
    public var id = UUID()
    public var role: Role
    public var text: String
    public var detail: String?
    public var timestamp = Date()
}

/// 대화 세션: 공급자 선택 → 도구 루프(최대 N회) → 턴 기록. 공급자를 바꿔도 대화 기록은 유지된다.
public actor AssistantSession {
    public private(set) var history: [LLMMessage] = []
    public private(set) var turns: [AssistantTurn] = []
    public private(set) var totalUsage = LLMUsage()
    public var maxToolRounds = 8
    private let tools: AssistantToolExecutor

    public init(tools: AssistantToolExecutor) { self.tools = tools }

    public func reset() { history.removeAll(); turns.removeAll(); totalUsage = LLMUsage() }

    /// 한 사용자 발화를 처리한다. 반환: 어시스턴트 최종 텍스트.
    public func send(_ text: String, provider: any LLMProvider, model: String, context: AssistantContext, effort: LLMRequest.Effort = .low) async throws -> String {
        history.append(.user(text))
        turns.append(AssistantTurn(role: .user, text: text))
        var rounds = 0
        while true {
            let req = LLMRequest(model: model, system: context.systemPrompt(), messages: history, tools: AssistantTools.all, maxOutputTokens: 2048, effort: effort)
            let resp = try await provider.complete(req)
            totalUsage.inputTokens += resp.usage.inputTokens; totalUsage.outputTokens += resp.usage.outputTokens
            history.append(.assistant(text: resp.text, toolCalls: resp.toolCalls))
            if !resp.text.isEmpty { turns.append(AssistantTurn(role: .assistant, text: resp.text)) }
            guard !resp.toolCalls.isEmpty, rounds < maxToolRounds else {
                if resp.toolCalls.isEmpty { return resp.text }
                let msg = "도구 호출 횟수 한도에 닿아 중단했습니다."
                turns.append(AssistantTurn(role: .assistant, text: msg)); return msg
            }
            rounds += 1
            var results: [LLMToolResult] = []
            for call in resp.toolCalls {
                let r = await tools.execute(call)
                results.append(r)
                turns.append(AssistantTurn(role: .tool, text: "\(call.name)", detail: r.content))
            }
            history.append(.toolResults(results))
        }
    }

    /// 측정 결과 정밀 분석 요청용 프롬프트 (정밀 등급 모델 권장).
    public static func measurementAnalysisPrompt() -> String {
        "get_measurement 로 최근 측정 결과를 읽고, (1) 목표 대비 가장 큰 편차 3가지와 원인(스피커/방), (2) 제안된 보정 필터의 우선순위, (3) EQ로 해결되지 않아 스피커 위치·각도·반사 처리로 봐야 할 항목을 한국어로 정리해 주세요. 수치는 앱이 계산한 값을 그대로 쓰세요."
    }
}
