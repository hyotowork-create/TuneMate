import Foundation

/// 한도·모드 검사 결과.
public enum GateVerdict: Equatable, Sendable {
    case apply                       // 바로 적용 가능
    case needsApproval([String])     // 사람 승인 필요 (이유)
    case denied([String])            // 적용 불가 (이유)

    public var isDenied: Bool { if case .denied = self { return true }; return false }
    public var reasons: [String] {
        switch self {
        case .apply: return []
        case .needsApproval(let r), .denied(let r): return r
        }
    }
}

/// 모든 믹서 변경은 이 게이트를 지난다.
public enum SafetyGate {
    public static func evaluate(_ proposal: ChangeProposal, state: MixerState, mode: OperatingMode, policy: SafetyPolicy,
                                protocolStatus: MixerModel.ProtocolStatus) -> GateVerdict {
        var denied: [String] = []
        var approval: [String] = []

        if mode == .serviceLock && !proposal.changes.isEmpty {
            return .denied(["예배 잠금 모드: 믹서를 변경하지 않습니다. 진단과 제안만 가능합니다."])
        }
        if policy.blockWritesToUnverifiedProtocol && protocolStatus == .unverified && !proposal.changes.isEmpty {
            return .denied(["이 믹서의 제어 프로토콜이 아직 검증되지 않았습니다. 변경안을 보고 공식 앱에서 직접 입력하세요."])
        }

        var muteCount = 0
        var missingBands: [String: (have: Int, want: Int)] = [:]   // 대상별: 믹서에 없는 EQ 밴드
        for r in ChangeResolver.resolve(proposal.changes, against: state) {
            let c = r.change
            if c.alwaysRequiresConfirmation { approval.append("\(r.summary): 항상 사람 확인이 필요한 변경입니다.") }
            switch r.absolute {
            case .faderAbsolute(let t, let new):
                let cur = state.faderDB(of: t) ?? -90
                let delta = new - cur
                if delta > policy.maxIncreaseStepDB + 1e-9 { approval.append(String(format: "%@: 한 번에 +%.1f dB 올립니다 (한도 +%.0f dB).", r.summary, delta, policy.maxIncreaseStepDB)) }
                if -delta > policy.maxDecreaseStepDB + 1e-9 { approval.append(String(format: "%@: 한 번에 %.1f dB 내립니다 (한도 −%.0f dB).", r.summary, delta, policy.maxDecreaseStepDB)) }
                if t == .mainLR && new > policy.mainOutputCapDB + 1e-9 { denied.append(String(format: "메인 출력 상한 %.0f dB를 넘습니다 (%.1f dB).", policy.mainOutputCapDB, new)) }
            case .auxSendAbsolute(let ch, let aux, let new):
                let cur = state.channel(ch)?.auxSendsDB[safe: aux - 1] ?? -90
                if new - cur > policy.maxIncreaseStepDB + 1e-9 { approval.append(String(format: "%@: 한 번에 +%.1f dB 올립니다.", r.summary, new - cur)) }
            case .mute(_, let on):
                if on { muteCount += 1 }
            case .eqBand(let t, let b, _, let g, _, let on):
                if abs(g) > policy.maxEQGainAbsDB + 1e-9 { denied.append(String(format: "%@: EQ 게인 한도 ±%.0f dB를 넘습니다.", r.summary, policy.maxEQGainAbsDB)) }
                let cur = state.eq(of: t)?.first { $0.index == b }
                // 믹서가 가진 밴드 수보다 큰 밴드 번호: 중간까지만 쓰이고 실패하지 않도록 통째로 막는다.
                if cur == nil, let bands = state.eq(of: t), !bands.isEmpty {
                    let key = "\(t)"
                    missingBands[key] = (bands.count, max(b, missingBands[key]?.want ?? 0))
                }
                let curG = (cur?.enabled ?? false) ? (cur?.gainDB ?? 0) : 0
                if on && g - curG > policy.maxIncreaseStepDB + 1e-9 { approval.append(String(format: "%@: 부스트 폭 +%.1f dB (한도 +%.0f dB).", r.summary, g - curG, policy.maxIncreaseStepDB)) }
                if on && g < policy.notch.maxDepthDB - 1e-9 { approval.append(String(format: "%@: 노치 한도 %.0f dB보다 깊습니다.", r.summary, policy.notch.maxDepthDB)) }
            case .preampGain:
                approval.append("\(r.summary): 프리앰프 게인은 사람 확인 뒤 바꿉니다.")
            default: break
            }
        }
        for (target, m) in missingBands.sorted(by: { $0.key < $1.key }) {
            denied.append("\(target) EQ는 \(m.have)밴드인데 \(m.want)밴드까지 쓰려 합니다. 밴드 수를 \(m.have) 이하로 줄여 다시 계산하세요.")
        }
        if muteCount > policy.maxMutesPerProposal { approval.append("한 번에 \(muteCount)개 채널을 뮤트합니다 (한도 \(policy.maxMutesPerProposal)개).") }

        if !denied.isEmpty { return .denied(denied) }
        if mode == .proposal { return .needsApproval(approval.isEmpty ? ["제안 모드: 적용 버튼을 눌러 확인합니다."] : approval) }
        return approval.isEmpty ? .apply : .needsApproval(approval)
    }
}
