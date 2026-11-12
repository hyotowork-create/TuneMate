import Testing
import Foundation
@testable import TuneMateCore

@Suite("Safety")
struct SafetyTests {
    func makeExecutor(mode: OperatingMode) async throws -> (ChangeExecutor, MockMixerDriver) {
        let drv = MockMixerDriver()
        try await drv.connect(host: "sim")
        let ex = ChangeExecutor(driver: drv, history: ChangeHistoryStore(), mode: mode)
        return (ex, drv)
    }

    @Test func serviceLockDeniesEverything() async throws {
        let (ex, _) = try await makeExecutor(mode: .serviceLock)
        let p = ChangeProposal(source: .ai, rationale: "t", changes: [.faderRelative(target: .channel(1), deltaDB: 1)])
        let out = try await ex.submit(p)
        guard case .denied = out else { Issue.record("expected denied"); return }
    }

    @Test func proposalModeWaitsForApprovalThenApplies() async throws {
        let (ex, drv) = try await makeExecutor(mode: .proposal)
        let p = ChangeProposal(source: .ai, rationale: "보컬 +2", changes: [.faderRelative(target: .channel(1), deltaDB: 2)])
        let out = try await ex.submit(p)
        guard case .awaitingApproval(let resolved, _) = out else { Issue.record("expected awaiting"); return }
        #expect(resolved.resolved.first?.summary == "CH1 페이더 -10.0 dB → -8.0 dB")
        let out2 = try await ex.submit(p, approved: true)
        guard case .applied = out2 else { Issue.record("expected applied"); return }
        let s = try await drv.snapshot()
        #expect(abs((s.channel(1)?.faderDB ?? 0) - (-8)) < 1e-9)
    }

    @Test func rehearsalAutoAppliesWithinLimitsAndAsksBeyond() async throws {
        let (ex, drv) = try await makeExecutor(mode: .rehearsalAuto)
        let small = ChangeProposal(source: .ai, rationale: "", changes: [.faderRelative(target: .channel(2), deltaDB: 3)])
        guard case .applied = try await ex.submit(small) else { Issue.record("small should apply"); return }
        let big = ChangeProposal(source: .ai, rationale: "", changes: [.faderRelative(target: .channel(2), deltaDB: 4)])
        guard case .awaitingApproval(_, let reasons) = try await ex.submit(big) else { Issue.record("big should wait"); return }
        #expect(reasons.first?.contains("한도") == true)
        // 메인 상한 초과 → 거절
        let main = ChangeProposal(source: .ai, rationale: "", changes: [.faderAbsolute(target: .mainLR, dB: 2)])
        guard case .denied = try await ex.submit(main, approved: true) else { Issue.record("main cap"); return }
        // 팬텀은 항상 승인
        let ph = ChangeProposal(source: .ai, rationale: "", changes: [.phantom(channel: 1, on: true)])
        guard case .awaitingApproval = try await ex.submit(ph) else { Issue.record("phantom"); return }
        // 뮤트 3개 → 승인
        let mutes = ChangeProposal(source: .ai, rationale: "", changes: (1...3).map { .mute(target: .channel($0), on: true) })
        guard case .awaitingApproval = try await ex.submit(mutes) else { Issue.record("mutes"); return }
        _ = drv
    }

    /// 믹서 메인 EQ(시뮬레이터 4밴드)에 없는 5·6밴드를 쓰는 변경안은 통째로 막고, 앞 밴드도 건드리지 않는다.
    @Test func eqBandBeyondMixerBandCountIsDeniedWithoutPartialWrite() async throws {
        let (ex, drv) = try await makeExecutor(mode: .rehearsalAuto)
        let before = try await drv.snapshot()
        let have = before.eq(of: .mainLR)?.count ?? 0
        #expect(have == 4)
        let changes: [MixerChange] = (1...6).map { .eqBand(target: .mainLR, band: $0, frequencyHz: 100 * Double($0), gainDB: -2, q: 2, on: true) }
        let out = try await ex.submit(ChangeProposal(source: .autoEQ, rationale: "6밴드", changes: changes), approved: true)
        guard case .denied(let reasons) = out else { Issue.record("expected denied, got \(out)"); return }
        #expect(reasons.count == 1)
        #expect(reasons[0].contains("4밴드") && reasons[0].contains("6밴드"))
        let after = try await drv.snapshot()
        #expect(after.eq(of: .mainLR) == before.eq(of: .mainLR))
        // 밴드 수 안이면 그대로 적용된다.
        let ok = try await ex.submit(ChangeProposal(source: .autoEQ, rationale: "4밴드", changes: Array(changes.prefix(4))), approved: true)
        guard case .applied = ok else { Issue.record("expected applied, got \(ok)"); return }
    }

    @Test func undoRestoresSnapshot() async throws {
        let (ex, drv) = try await makeExecutor(mode: .rehearsalAuto)
        let before = try await drv.snapshot()
        let p = ChangeProposal(source: .feedbackSuppressor, rationale: "notch", changes: [
            .eqBand(target: .channel(1), band: 2, frequencyHz: 2480, gainDB: -3, q: 10, on: true),
            .faderRelative(target: .channel(3), deltaDB: -2)])
        guard case .applied = try await ex.submit(p) else { Issue.record("apply"); return }
        let mid = try await drv.snapshot()
        #expect(mid.channel(1)?.eq[1].gainDB == -3)
        let undone = try await ex.undoLast()
        #expect(undone != nil)
        let after = try await drv.snapshot()
        #expect(after.channels == before.channels)
        #expect(after.outputs == before.outputs)
    }

    @Test func unverifiedProtocolBlocksWrites() async throws {
        let drv = MockMixerDriver(model: .dm248)
        try await drv.connect(host: "sim")
        let ex = ChangeExecutor(driver: drv, history: ChangeHistoryStore(), mode: .rehearsalAuto)
        let p = ChangeProposal(source: .ai, rationale: "", changes: [.faderRelative(target: .channel(1), deltaDB: 1)])
        guard case .denied(let r) = try await ex.submit(p, approved: true) else { Issue.record("should deny"); return }
        #expect(r.first?.contains("검증") == true)
    }
}
