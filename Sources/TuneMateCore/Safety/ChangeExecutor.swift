import Foundation

public enum ExecutionOutcome: Equatable, Sendable {
    case applied(ChangeLogEntry)
    case awaitingApproval(ChangeProposal, reasons: [String])
    case denied(reasons: [String])
}

/// 게이트 → 자동 스냅샷 → 적용 → 로그 → (되돌리기). 믹서에 쓰는 유일한 경로.
public actor ChangeExecutor {
    public let driver: any MixerDriver
    public let history: ChangeHistoryStore
    public var mode: OperatingMode
    public var policy: SafetyPolicy

    public init(driver: any MixerDriver, history: ChangeHistoryStore, mode: OperatingMode = .proposal, policy: SafetyPolicy = SafetyPolicy()) {
        self.driver = driver; self.history = history; self.mode = mode; self.policy = policy
    }

    public func setMode(_ m: OperatingMode) { mode = m }
    public func setPolicy(_ p: SafetyPolicy) { policy = p }

    /// 변경안을 평가하고, 가능하면 적용한다. `approved` 가 true면 사람이 승인한 것으로 본다.
    public func submit(_ proposal: ChangeProposal, approved: Bool = false) async throws -> ExecutionOutcome {
        let state = try await driver.snapshot()
        var p = proposal
        p.resolved = ChangeResolver.resolve(p.changes, against: state)
        let verdict = SafetyGate.evaluate(p, state: state, mode: mode, policy: policy, protocolStatus: driver.model.protocolStatus)
        switch verdict {
        case .denied(let r): return .denied(reasons: r)
        case .needsApproval(let r):
            if !approved { return .awaitingApproval(p, reasons: r) }
        case .apply: break
        }
        let snap = await history.addSnapshot(state, reason: "변경 전 자동 백업 (\(p.source.rawValue))")
        var entry = ChangeLogEntry(proposalID: p.id, source: p.source, mode: mode, summaries: p.resolved.map(\.summary),
                                   approvedBy: approved ? "user" : "auto", snapshotID: snap.id)
        do {
            for r in p.resolved { try await apply(r.absolute) }
        } catch {
            entry.error = "\(error)"
            await history.append(entry)
            throw error
        }
        await history.append(entry)
        return .applied(entry)
    }

    /// 마지막 변경을 스냅샷으로 되돌린다 (원클릭 되돌리기).
    public func undoLast() async throws -> ChangeLogEntry? {
        guard let e = await history.lastUndoable, let sid = e.snapshotID, let snap = await history.snapshot(id: sid) else { return nil }
        try await driver.restore(snap.state)
        await history.markUndone(e.id)
        var restoreEntry = ChangeLogEntry(proposalID: e.proposalID, source: .restore, mode: mode, summaries: ["되돌리기: " + e.summaries.joined(separator: "; ")], approvedBy: "user", snapshotID: nil)
        restoreEntry.undone = true
        await history.append(restoreEntry)
        return e
    }

    public func restore(snapshotID: UUID) async throws {
        guard let snap = await history.snapshot(id: snapshotID) else { throw MixerError.unsupported("snapshot not found") }
        try await driver.restore(snap.state)
        await history.append(ChangeLogEntry(proposalID: snap.id, source: .restore, mode: mode, summaries: ["스냅샷 복원: \(snap.reason)"], approvedBy: "user", snapshotID: nil))
    }

    private func apply(_ c: MixerChange) async throws {
        switch c {
        case .faderAbsolute(let t, let v): try await driver.setFader(t, dB: v)
        case .faderRelative: preconditionFailure("relative change must be resolved first")
        case .mute(let t, let on): try await driver.setMute(t, on: on)
        case .eqBand(let t, let b, let f, let g, let q, let on): try await driver.setEQBand(t, band: b, frequencyHz: f, gainDB: g, q: q, on: on)
        case .eqEnabled(let t, let on): try await driver.setEQEnabled(t, on: on)
        case .auxSendAbsolute(let ch, let aux, let v): try await driver.setAuxSend(channel: ch, aux: aux, dB: v)
        case .auxSendRelative: preconditionFailure("relative change must be resolved first")
        case .preampGain(let ch, let v): try await driver.setPreampGain(channel: ch, dB: v)
        case .pan(let ch, let p): try await driver.setPan(channel: ch, pan: p)
        case .delay(let o, let ms): try await driver.setDelay(output: o, ms: ms)
        case .phantom(let ch, let on): try await driver.setPhantom(channel: ch, on: on)
        case .sceneRecall(let n): try await driver.recallScene(number: n)
        case .routing(let d): throw MixerError.unsupported("routing: \(d)")
        }
    }
}
