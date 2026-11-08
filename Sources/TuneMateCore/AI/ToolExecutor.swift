import Foundation

/// AI 가 보는 최근 측정 요약.
public struct MeasurementSummary: Codable, Equatable, Sendable {
    public var measuredAt: Date
    public var positions: Int
    public var microphone: String
    public var bandSummary: [String]          // "63 Hz: +4.2 dB (목표 대비)"
    public var proposedFilters: [EQAssignment]
    public var excludedDips: [String]
    public var notes: [String]
    public var residualRMSDB: Double
    public var initialRMSDB: Double
    public var feedbackCandidates: [String]
    public init(measuredAt: Date, positions: Int, microphone: String, bandSummary: [String], proposedFilters: [EQAssignment], excludedDips: [String], notes: [String], residualRMSDB: Double, initialRMSDB: Double, feedbackCandidates: [String]) {
        self.measuredAt = measuredAt; self.positions = positions; self.microphone = microphone; self.bandSummary = bandSummary; self.proposedFilters = proposedFilters
        self.excludedDips = excludedDips; self.notes = notes; self.residualRMSDB = residualRMSDB; self.initialRMSDB = initialRMSDB; self.feedbackCandidates = feedbackCandidates
    }

    public static func from(_ r: AutoEQResult, positions: Int, microphone: String, feedback: [FeedbackCandidate]) -> MeasurementSummary {
        // 1/3옥타브 요약
        var bands: [String] = []
        let centers: [Double] = [31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000]
        for c in centers {
            let err = r.measured.magnitudeDB(at: c) - r.target.magnitudeDB(at: c)
            if abs(err) >= 1.5 { bands.append(String(format: "%@: %+.1f dB", c >= 1000 ? String(format: "%.1fk", c / 1000) : String(format: "%.0f Hz", c), err)) }
        }
        return MeasurementSummary(measuredAt: Date(), positions: positions, microphone: microphone, bandSummary: bands,
                                  proposedFilters: EQAssignment.fromResult(r),
                                  excludedDips: r.excludedDips.map { String(format: "%.0f–%.0f Hz", $0.lowerBound, $0.upperBound) },
                                  notes: r.notes, residualRMSDB: r.residualRMSDB, initialRMSDB: r.initialRMSDB,
                                  feedbackCandidates: feedback.map { String(format: "%.0f Hz (돌출 %.0f dB, 신뢰도 %.0f%%)", $0.frequencyHz, $0.prominenceDB, $0.confidence * 100) })
    }
}

/// 도구 호출을 앱 서비스로 연결한다. 쓰기 도구는 전부 ChangeExecutor(안전 계층)를 지난다.
public actor AssistantToolExecutor {
    public let executor: ChangeExecutor
    public var latestLevels: Levels?
    public var latestMeasurement: MeasurementSummary?
    public private(set) var pendingProposals: [UUID: ChangeProposal] = [:]
    /// 이 기기가 믹서에 직접 연결되지 않았을 때 콘솔 기기가 공유한 상태
    public var remoteState: MixerState?
    /// 쓰기 도구를 원격 콘솔로 보내는 경로 (설정되면 로컬 실행기 대신 사용)
    public var remoteSubmit: (@Sendable (ChangeProposal) async -> String)?
    /// UI가 승인 UI를 띄우도록 알려 주는 콜백 (승인 결과 true/false)
    public var approvalHandler: (@Sendable (ChangeProposal, [String]) async -> Bool)?

    public init(executor: ChangeExecutor) { self.executor = executor }

    public func setLevels(_ l: Levels?) { latestLevels = l }
    public func setMeasurement(_ m: MeasurementSummary?) { latestMeasurement = m }
    public func setApprovalHandler(_ h: (@Sendable (ChangeProposal, [String]) async -> Bool)?) { approvalHandler = h }
    public func setRemote(state: MixerState?, submit: (@Sendable (ChangeProposal) async -> String)?) { remoteState = state; remoteSubmit = submit }

    private func currentState() async throws -> MixerState {
        if let r = remoteState { return r }
        return try await executor.driver.snapshot()
    }

    public func execute(_ call: LLMToolCall) async -> LLMToolResult {
        do {
            let out = try await run(call)
            return LLMToolResult(callID: call.id, name: call.name, content: out)
        } catch {
            return LLMToolResult(callID: call.id, name: call.name, content: "오류: \(error)", isError: true)
        }
    }

    private func run(_ call: LLMToolCall) async throws -> String {
        let a = call.arguments
        switch call.name {
        case "get_mixer_state":
            return try await currentState().summary() + (remoteState != nil ? "\n(콘솔 기기가 공유한 상태)" : "")
        case "get_channel":
            guard let n = a["channel"]?.intValue, let c = try await currentState().channel(n) else { return "채널을 찾을 수 없습니다." }
            return try JSONValue.parse(JSONEncoder().encode(c)).jsonString()
        case "get_meters":
            if let l = latestLevels {
                return l.channelsDB.enumerated().map { String(format: "CH%d: %.0f dB", $0.offset + 1, $0.element) }.joined(separator: ", ")
            }
            if let stream = await executor.driver.meters() {
                for await l in stream { latestLevels = l; break }
                if let l = latestLevels { return l.channelsDB.enumerated().map { String(format: "CH%d: %.0f dB", $0.offset + 1, $0.element) }.joined(separator: ", ") }
            }
            return "이 믹서는 미터 스트림을 제공하지 않습니다 (DM24.8은 Phase 0 확인 항목)."
        case "get_measurement":
            guard let m = latestMeasurement else { return "아직 측정 결과가 없습니다. 측정 탭에서 좌석 5~8곳을 측정하세요." }
            return try JSONValue.parse(JSONEncoder().encode(m)).jsonString()
        case "propose_changes":
            let changes = (a["changes"]?.arrayValue ?? []).compactMap(AssistantTools.parseChange)
            guard !changes.isEmpty else { return "해석할 수 있는 변경이 없습니다. kind/target 을 확인하세요." }
            let p = ChangeProposal(source: .ai, rationale: a["rationale"]?.stringValue ?? "", changes: changes)
            let state = try await currentState()
            var resolved = p; resolved.resolved = ChangeResolver.resolve(changes, against: state)
            pendingProposals[p.id] = resolved
            return "변경안 \(p.id.uuidString) 생성:\n" + resolved.resolved.map { "- " + $0.summary }.joined(separator: "\n") + "\n적용하려면 apply_changes(proposal_id)."
        case "apply_changes":
            guard let idStr = a["proposal_id"]?.stringValue, let id = UUID(uuidString: idStr), let p = pendingProposals[id] else { return "변경안을 찾을 수 없습니다." }
            return try await submit(p)
        case "adjust_fader":
            guard let t = a["target"]?.stringValue.flatMap({ EQTarget(parsing: $0) }), let d = a["delta_db"]?.doubleValue else { return "target/delta_db 가 필요합니다." }
            return try await submit(ChangeProposal(source: .ai, rationale: a["reason"]?.stringValue ?? "", changes: [.faderRelative(target: t, deltaDB: d)]))
        case "adjust_send":
            guard let ch = a["channel"]?.intValue, let aux = a["aux"]?.intValue, let d = a["delta_db"]?.doubleValue else { return "channel/aux/delta_db 가 필요합니다." }
            return try await submit(ChangeProposal(source: .ai, rationale: a["reason"]?.stringValue ?? "", changes: [.auxSendRelative(channel: ch, aux: aux, deltaDB: d)]))
        case "set_eq_band":
            guard let t = a["target"]?.stringValue.flatMap({ EQTarget(parsing: $0) }), let b = a["band"]?.intValue, let f = a["frequency_hz"]?.doubleValue, let g = a["gain_db"]?.doubleValue, let q = a["q"]?.doubleValue else { return "입력이 부족합니다." }
            return try await submit(ChangeProposal(source: .ai, rationale: a["reason"]?.stringValue ?? "", changes: [.eqBand(target: t, band: b, frequencyHz: f, gainDB: g, q: q, on: a["on"]?.boolValue ?? true)]))
        case "backup_scene":
            let s = try await executor.driver.snapshot()
            let snap = await executor.history.addSnapshot(s, reason: a["note"]?.stringValue ?? "AI 요청 백업")
            return "스냅샷 저장됨: \(snap.id.uuidString)"
        case "restore_scene":
            guard a["confirm"]?.boolValue == true else { return "사용자 확인이 필요합니다. 되돌릴지 사용자에게 물어보세요." }
            if let h = approvalHandler {
                let ok = await h(ChangeProposal(source: .restore, rationale: "마지막 변경 되돌리기", changes: []), ["스냅샷 복원은 항상 사람 확인이 필요합니다."])
                guard ok else { return "사용자가 되돌리기를 거절했습니다." }
            }
            if let e = try await executor.undoLast() { return "되돌렸습니다: " + e.summaries.joined(separator: "; ") }
            return "되돌릴 변경이 없습니다."
        default:
            return "알 수 없는 도구: \(call.name)"
        }
    }

    private func submit(_ p: ChangeProposal) async throws -> String {
        if let remote = remoteSubmit { return await remote(p) }
        let outcome = try await executor.submit(p)
        switch outcome {
        case .applied(let e): return "적용됨 (\(e.mode.displayName)): " + e.summaries.joined(separator: "; ") + ". 스냅샷이 저장되어 되돌릴 수 있습니다."
        case .denied(let reasons): return "적용 불가: " + reasons.joined(separator: " ")
        case .awaitingApproval(let resolved, let reasons):
            guard let h = approvalHandler else { return "승인 필요: " + reasons.joined(separator: " ") + "\n" + resolved.resolved.map(\.summary).joined(separator: "\n") }
            let ok = await h(resolved, reasons)
            guard ok else { return "사용자가 승인하지 않았습니다. 변경을 적용하지 않았습니다." }
            let second = try await executor.submit(resolved, approved: true)
            if case .applied(let e) = second { return "사용자 승인 후 적용됨: " + e.summaries.joined(separator: "; ") }
            if case .denied(let r) = second { return "적용 불가: " + r.joined(separator: " ") }
            return "적용되지 않았습니다."
        }
    }
}
