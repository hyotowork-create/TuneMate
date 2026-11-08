import Foundation

/// 기획서 7장 도구 명세. 모든 공급자에 같은 정의를 넘긴다.
public enum AssistantTools {
    static let targetDesc = "대상: CH1~CH24 / AUX1~AUX8 / MAIN"

    public static let all: [LLMToolDefinition] = [
        LLMToolDefinition(name: "get_mixer_state", description: "전체 채널·출력 상태 요약 (페이더, 뮤트, EQ, 센드). 믹서 변경 없음.",
                          parameters: ["type": "object", "properties": [:], "additionalProperties": false]),
        LLMToolDefinition(name: "get_channel", description: "한 채널의 게인·EQ·다이내믹스·센드 상세. 믹서 변경 없음.",
                          parameters: ["type": "object", "properties": ["channel": ["type": "integer", "description": "채널 번호 (1부터)"]], "required": ["channel"], "additionalProperties": false]),
        LLMToolDefinition(name: "get_meters", description: "채널별 현재 레벨(dB). 신호가 들어오는지 확인할 때 쓴다. 믹서 변경 없음.",
                          parameters: ["type": "object", "properties": [:], "additionalProperties": false]),
        LLMToolDefinition(name: "get_measurement", description: "최근 공간 측정 결과(평균 응답 요약, 보정 제안 필터, 제외된 딥, 하울링 후보). 믹서 변경 없음.",
                          parameters: ["type": "object", "properties": [:], "additionalProperties": false]),
        LLMToolDefinition(name: "propose_changes", description: "변경안 목록을 만들어 사용자에게 보여 준다 (적용하지 않음). 값은 상대값(±dB)만 쓴다. 적용은 사용자가 승인한 뒤 apply_changes 로.",
                          parameters: ["type": "object", "properties": [
                            "rationale": ["type": "string", "description": "이 변경을 제안하는 이유 (한국어, 한두 문장)"],
                            "changes": ["type": "array", "items": changeSchema]
                          ], "required": ["rationale", "changes"], "additionalProperties": false]),
        LLMToolDefinition(name: "apply_changes", description: "propose_changes 로 만든 변경안을 적용 요청한다. 제안 모드에서는 사용자 승인 버튼이 뜨고, 리허설 자동 모드에서는 한도 안이면 바로 적용된다. 예배 잠금 모드에서는 거절된다.",
                          parameters: ["type": "object", "properties": ["proposal_id": ["type": "string"]], "required": ["proposal_id"], "additionalProperties": false]),
        LLMToolDefinition(name: "adjust_fader", description: "페이더를 상대값(±dB)으로 조정 (변경안 1건 생성 후 적용 요청). \(targetDesc)",
                          parameters: ["type": "object", "properties": ["target": ["type": "string"], "delta_db": ["type": "number"], "reason": ["type": "string"]], "required": ["target", "delta_db"], "additionalProperties": false]),
        LLMToolDefinition(name: "adjust_send", description: "채널→AUX 센드를 상대값(±dB)으로 조정 (변경안 1건 생성 후 적용 요청).",
                          parameters: ["type": "object", "properties": ["channel": ["type": "integer"], "aux": ["type": "integer"], "delta_db": ["type": "number"], "reason": ["type": "string"]], "required": ["channel", "aux", "delta_db"], "additionalProperties": false]),
        LLMToolDefinition(name: "set_eq_band", description: "EQ 밴드 설정 (변경안 1건 생성 후 적용 요청). \(targetDesc)",
                          parameters: ["type": "object", "properties": ["target": ["type": "string"], "band": ["type": "integer"], "frequency_hz": ["type": "number"], "gain_db": ["type": "number"], "q": ["type": "number"], "on": ["type": "boolean"], "reason": ["type": "string"]],
                                       "required": ["target", "band", "frequency_hz", "gain_db", "q"], "additionalProperties": false]),
        LLMToolDefinition(name: "backup_scene", description: "현재 믹서 상태 스냅샷을 저장한다 (승인 불필요).",
                          parameters: ["type": "object", "properties": ["note": ["type": "string"]], "additionalProperties": false]),
        LLMToolDefinition(name: "restore_scene", description: "마지막 변경을 되돌린다(스냅샷 복원). 항상 사용자 승인이 필요하다.",
                          parameters: ["type": "object", "properties": ["confirm": ["type": "boolean", "description": "사용자가 되돌리기를 명시적으로 요청했으면 true"]], "required": ["confirm"], "additionalProperties": false])
    ]

    static let changeSchema: JSONValue = ["type": "object", "properties": [
        "kind": ["type": "string", "enum": ["fader", "mute", "eq_band", "aux_send", "pan", "phantom", "scene_recall"]],
        "target": ["type": "string", "description": .string(targetDesc)],
        "delta_db": ["type": "number", "description": "fader/aux_send 상대값"],
        "on": ["type": "boolean", "description": "mute/phantom/eq on"],
        "aux": ["type": "integer"],
        "band": ["type": "integer"],
        "frequency_hz": ["type": "number"],
        "gain_db": ["type": "number"],
        "q": ["type": "number"],
        "pan": ["type": "number"],
        "scene": ["type": "integer"]
    ], "required": ["kind", "target"], "additionalProperties": false]

    /// 도구 입력 → MixerChange
    public static func parseChange(_ j: JSONValue) -> MixerChange? {
        guard let kind = j["kind"]?.stringValue, let tStr = j["target"]?.stringValue, let target = EQTarget(parsing: tStr) else { return nil }
        switch kind {
        case "fader": guard let d = j["delta_db"]?.doubleValue else { return nil }; return .faderRelative(target: target, deltaDB: d)
        case "mute": return .mute(target: target, on: j["on"]?.boolValue ?? true)
        case "eq_band":
            guard let b = j["band"]?.intValue, let f = j["frequency_hz"]?.doubleValue, let g = j["gain_db"]?.doubleValue else { return nil }
            return .eqBand(target: target, band: b, frequencyHz: f, gainDB: g, q: j["q"]?.doubleValue ?? 2.0, on: j["on"]?.boolValue ?? true)
        case "aux_send":
            guard case .channel(let ch) = target, let aux = j["aux"]?.intValue, let d = j["delta_db"]?.doubleValue else { return nil }
            return .auxSendRelative(channel: ch, aux: aux, deltaDB: d)
        case "pan": guard case .channel(let ch) = target, let p = j["pan"]?.doubleValue else { return nil }; return .pan(channel: ch, pan: p)
        case "phantom": guard case .channel(let ch) = target else { return nil }; return .phantom(channel: ch, on: j["on"]?.boolValue ?? true)
        case "scene_recall": guard let n = j["scene"]?.intValue else { return nil }; return .sceneRecall(number: n)
        default: return nil
        }
    }
}
