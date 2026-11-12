import Foundation
import SwiftUI
import TuneMateCore

/// 앱 전체 상태. 서비스(저장소·믹서·안전 계층·AI)를 묶고 화면에 상태를 내보낸다.
@MainActor
final class AppModel: ObservableObject {
    // 설정·저장
    let store: AppStore
    @Published var settings = AppSettings()
    @Published var sessions: [MeasurementSession] = []

    // 믹서
    @Published private(set) var driver: any MixerDriver
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var mixerState: MixerState?
    @Published var levels: Levels?
    @Published var discovered: [DiscoveredMixer] = []
    @Published var isDiscovering = false
    @Published var changeLog: [ChangeLogEntry] = []
    private var meterTask: Task<Void, Never>?
    private(set) var history: ChangeHistoryStore
    private(set) var executor: ChangeExecutor
    private(set) var toolExecutor: AssistantToolExecutor

    // 측정
    @Published var currentSession: MeasurementSession
    @Published var isMeasuring = false
    @Published var measureStatus = ""
    @Published var audioInfo: AudioDeviceInfo?
    @Published var calibration: MicrophoneCalibration?
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var selectedInputDevice: AudioInputDevice?
    @Published var inputLevel: InputLevel?
    @Published var isLevelMonitoring = false
    @Published var isPlayingNoise = false
    @Published var probeResult: ProbeResult?
    @Published var isProbing = false
    @Published var snapshots: [MixerSnapshot] = []
    let peerLink = PeerLink()
    let overlay = OverlayPresenter()
    /// 이 기기가 믹서에 연결됐을 때 다른 기기의 변경안을 받아 적용할지
    @Published var actAsConsole = true
    @Published var remoteOutcomes: [RemoteOutcome] = []
    @Published var lastRemoteResult = ""
    private var remoteWaiters: [UUID: CheckedContinuation<RemoteOutcome, Never>] = [:]
    var remoteConsole: ConsoleStatus? { connectionStatus == .connected ? nil : peerLink.activeConsole }

    // 튜닝 루프 (검증)
    @Published var isVerificationMode = false
    @Published var verificationPositions: [PositionMeasurement] = []
    @Published var tuningVerdict: TuningVerdict?

    // 하울링 자동 억제·링아웃
    @Published var autoSuppress = false
    @Published var suppressionEvents: [SuppressionEvent] = []
    @Published var ringOut: RingOutSession?
    private let suppressor = FeedbackSuppressor()
    private var isSuppressing = false

    // 하울링
    @Published var isMonitoring = false
    @Published var liveSpectrum: FrequencyResponse?
    @Published var feedbackCandidates: [FeedbackCandidate] = []
    private let detector = FeedbackDetector()
    private var rta: RealTimeAnalyzer?
    #if canImport(AVFoundation)
    private let audio = MeasurementAudioEngine()
    #endif

    // AI
    let secrets: SecretStore
    @Published var chatTurns: [AssistantTurn] = []
    @Published var isThinking = false
    @Published var usage = LLMUsage()
    @Published var lastError: String?
    private var session: AssistantSession

    // 승인
    struct PendingApproval: Identifiable { let id = UUID(); let proposal: ChangeProposal; let reasons: [String] }
    @Published var pendingApproval: PendingApproval?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?

    init(store: AppStore = AppStore(), secrets: SecretStore? = nil) {
        self.store = store
        #if canImport(Security)
        self.secrets = secrets ?? KeychainStore()
        #else
        self.secrets = secrets ?? InMemorySecretStore()
        #endif
        let drv = MockMixerDriver()
        self.driver = drv
        let hist = ChangeHistoryStore(directory: AppStore.defaultRoot().appendingPathComponent("history"))
        self.history = hist
        let ex = ChangeExecutor(driver: drv, history: hist)
        self.executor = ex
        let te = AssistantToolExecutor(executor: ex)
        self.toolExecutor = te
        self.session = AssistantSession(tools: te)
        self.currentSession = MeasurementSession(venueName: "본당", microphone: .simulated)
    }

    func load() async {
        settings = await store.settings
        sessions = await store.sessions
        currentSession = MeasurementSession(venueName: settings.venue.name, microphone: settings.microphone, sweep: settings.sweep, target: settings.target, autoEQOptions: settings.autoEQ)
        if let t = settings.calibrationText { calibration = try? MicrophoneCalibration.parse(t) }
        await rebuildDriver()
        await toolExecutor.setApprovalHandler { [weak self] proposal, reasons in
            guard let self else { return false }
            return await self.requestApproval(proposal, reasons: reasons)
        }
        changeLog = await history.log
        peerLink.onMessage = { [weak self] msg, from in self?.handlePeer(msg, from: from) }
        peerLink.onInstructionReceived = { [weak self] ins in
            OverlayPresenter.notify(ins)
            if self?.overlay.isActive == true { self?.overlay.update(ins) }
        }
        peerLink.onInstructionChanged = { [weak self] ins in if self?.overlay.isActive == true { self?.overlay.update(ins) } }
        OverlayPresenter.requestNotificationPermission()
        peerLink.onPeerConnected = { [weak self] _ in self?.broadcastConsoleStatus(); self?.broadcastVenue() }
        actAsConsole = settings.actAsConsole
        if settings.autoStartPeerLink { peerLink.start() }
        if settings.autoConnectMixer { await connectMixer() }
    }

    // MARK: 기기 연동

    private func handlePeer(_ msg: PeerMessage, from: String) {
        switch msg {
        case .proposal(let requestID, let proposal):
            guard actAsConsole, connectionStatus == .connected else {
                peerLink.send(.outcome(RemoteOutcome(requestID: requestID, kind: .denied, summaries: [], reasons: ["이 기기는 믹서에 연결되어 있지 않습니다."], by: peerLink.deviceName)), to: from)
                return
            }
            Task { await self.applyRemote(requestID: requestID, proposal: proposal, from: from) }
        case .outcome(let o):
            remoteOutcomes.append(o)
            remoteWaiters.removeValue(forKey: o.requestID)?.resume(returning: o)
        case .console(let st):
            if connectionStatus != .connected {
                Task { await toolExecutor.setRemote(state: st.state, submit: { [weak self] p in await self?.submitRemote(p) ?? "연동 기기 없음" }) }
            }
        case .measurement(let session):
            Task {
                await store.save(session)
                sessions = await store.sessions
                if currentSession.positions.isEmpty || currentSession.id == session.id { currentSession = session }
                if let r = session.result { await toolExecutor.setMeasurement(MeasurementSummary.from(r, positions: session.positions.count, microphone: session.microphone.displayName, feedback: [])) }
                peerLink.lastEvent = "\(from) 의 측정 결과를 받았습니다 (\(session.positions.count)지점)"
            }
        case .venue(let v):
            settings.venue = v; saveSettings()
        case .feedback(let cands, let who):
            if !isMonitoring { feedbackCandidates = cands; peerLink.lastEvent = "\(who) 의 하울링 후보 \(cands.count)건" }
        default: break
        }
    }

    /// 콘솔 기기: 받은 변경안을 로컬 안전 계층으로 적용하고 결과를 돌려보낸다.
    private func applyRemote(requestID: UUID, proposal: ChangeProposal, from: String) async {
        var p = proposal; p.rationale = "[\(from)] " + proposal.rationale
        func reply(_ kind: RemoteOutcome.Kind, _ summaries: [String], _ reasons: [String]) {
            peerLink.send(.outcome(RemoteOutcome(requestID: requestID, kind: kind, summaries: summaries, reasons: reasons, by: peerLink.deviceName)), to: from)
            broadcastConsoleStatus()
        }
        do {
            switch try await executor.submit(p) {
            case .applied(let e): await refreshState(); reply(.applied, e.summaries, [])
            case .denied(let r): reply(.denied, [], r)
            case .awaitingApproval(let resolved, let reasons):
                let ok = await requestApproval(resolved, reasons: reasons)
                guard ok else { reply(.rejectedByUser, [], ["콘솔 담당자가 거절했습니다."]); return }
                switch try await executor.submit(resolved, approved: true) {
                case .applied(let e): await refreshState(); reply(.applied, e.summaries, [])
                case .denied(let r): reply(.denied, [], r)
                case .awaitingApproval: reply(.error, [], ["승인 뒤에도 적용되지 않았습니다."])
                }
            }
        } catch { reply(.error, [], ["\(error)"]) }
    }

    /// 다른 기기: 변경안을 콘솔 기기로 보내고 결과를 기다린다 (최대 90초).
    func submitRemote(_ proposal: ChangeProposal) async -> String {
        guard let console = remoteConsole else { return "믹서에 연결된 콘솔 기기가 없습니다." }
        let id = UUID()
        guard peerLink.send(.proposal(requestID: id, proposal: proposal), to: console.deviceName) else { return "콘솔 기기로 보내지 못했습니다." }
        let outcome: RemoteOutcome? = await withTaskGroup(of: RemoteOutcome?.self) { group in
            group.addTask { await withCheckedContinuation { c in Task { @MainActor in self.remoteWaiters[id] = c } } }
            group.addTask { try? await Task.sleep(nanoseconds: 90_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        remoteWaiters.removeValue(forKey: id)
        guard let o = outcome else { return "콘솔 기기(\(console.deviceName))의 응답이 없습니다 (90초)." }
        switch o.kind {
        case .applied: return "콘솔 \(o.by)에서 적용됨: " + o.summaries.joined(separator: "; ")
        case .denied: return "콘솔에서 적용 불가: " + o.reasons.joined(separator: " ")
        case .rejectedByUser: return "콘솔 담당자가 거절했습니다."
        case .error: return "콘솔 오류: " + o.reasons.joined(separator: " ")
        }
    }

    func broadcastConsoleStatus() {
        guard peerLink.isActive else { return }
        peerLink.broadcast(.console(ConsoleStatus(deviceName: peerLink.deviceName, connected: connectionStatus == .connected, model: settings.mixerModel, mode: settings.mode, state: mixerState, acceptsRemoteProposals: actAsConsole)))
    }
    func broadcastVenue() { guard peerLink.isActive else { return }; peerLink.broadcast(.venue(settings.venue)) }
    func shareMeasurement() -> String {
        guard !currentSession.positions.isEmpty else { return "공유할 측정이 없습니다." }
        return peerLink.broadcast(.measurement(currentSession)) ? "측정 결과를 연결된 기기에 보냈습니다." : "연결된 기기가 없습니다."
    }

    func saveSettings() {
        let s = settings
        Task {
            await store.saveSettings(s)
            await executor.setMode(s.mode)
            await executor.setPolicy(s.policy)
        }
        detector.options = s.feedback
        broadcastConsoleStatus()
    }

    // MARK: 믹서

    func rebuildDriver() async {
        meterTask?.cancel(); levels = nil
        await driver.disconnect()
        let model = settings.mixerModel
        let newDriver: any MixerDriver = (try? MixerDriverFactory.make(for: model)) ?? MockMixerDriver(model: model)
        driver = newDriver
        executor = ChangeExecutor(driver: newDriver, history: history, mode: settings.mode, policy: settings.policy)
        toolExecutor = AssistantToolExecutor(executor: executor)
        await toolExecutor.setApprovalHandler { [weak self] p, r in await self?.requestApproval(p, reasons: r) ?? false }
        session = AssistantSession(tools: toolExecutor)
        chatTurns = []
        connectionStatus = .disconnected
        mixerState = nil
    }

    func connectMixer() async {
        lastError = nil
        connectionStatus = .connecting
        do {
            try await driver.connect(host: settings.mixerHost.isEmpty ? "sim" : settings.mixerHost)
            connectionStatus = .connected
            await refreshState()
            startMeters()
            broadcastConsoleStatus()
        } catch {
            connectionStatus = .failed("\(error)")
            lastError = "\(error)"
        }
    }

    func disconnectMixer() async {
        meterTask?.cancel()
        await driver.disconnect()
        connectionStatus = .disconnected
        levels = nil
        broadcastConsoleStatus()
    }

    func refreshState() async {
        do { mixerState = try await driver.snapshot() } catch { lastError = "\(error)" }
        changeLog = await history.log
        snapshots = await history.snapshots
    }

    func restoreSnapshot(_ id: UUID) async {
        do { try await executor.restore(snapshotID: id); await refreshState() } catch { lastError = "\(error)" }
    }

    func saveScene(number: Int, name: String) async {
        do {
            try await driver.saveScene(number: number, name: name)
            let s = try await driver.snapshot()
            _ = await history.addSnapshot(s, reason: "씬 \(number) \(name) 저장")
            await refreshState()
        } catch { lastError = "\(error)" }
    }

    private func startMeters() {
        meterTask?.cancel()
        let drv = driver
        meterTask = Task { [weak self] in
            guard let stream = await drv.meters() else { return }
            for await l in stream {
                guard !Task.isCancelled else { break }
                self?.levels = l
                await self?.toolExecutor.setLevels(l)
            }
        }
    }

    /// 입력한 IP 로 직접 연결 테스트.
    func probeMixer() async {
        isProbing = true; probeResult = nil; lastError = nil
        let r = await MixerProbe.probe(host: settings.mixerHost, family: settings.mixerFamily)
        probeResult = r
        if r.ok, let m = r.model, m != settings.mixerModel {
            settings.mixerFamily = m.family; settings.mixerModelName = m.name; saveSettings(); await rebuildDriver()
        }
        isProbing = false
    }

    func discoverMixers() async {
        isDiscovering = true
        var opt = MixerDiscovery.Options()
        if !settings.mixerHost.isEmpty { opt.yamahaHosts = [settings.mixerHost] }
        discovered = await MixerDiscovery().scan(options: opt)
        isDiscovering = false
    }

    func select(_ d: DiscoveredMixer) async {
        settings.mixerFamily = d.model.family
        settings.mixerModelName = d.model.name
        settings.mixerHost = d.host
        saveSettings()
        await rebuildDriver()
    }

    func undoLast() async {
        do { _ = try await executor.undoLast(); await refreshState() } catch { lastError = "\(error)" }
    }

    /// 사람(화면)에서 직접 만든 변경안 제출. 이 기기가 미연결이고 콘솔 기기가 있으면 원격 적용 요청.
    func submit(_ proposal: ChangeProposal, approved: Bool = false) async -> ExecutionOutcome? {
        if connectionStatus != .connected, remoteConsole != nil {
            let text = await submitRemote(proposal)
            lastRemoteResult = text
            if text.contains("적용됨") {
                return .applied(ChangeLogEntry(proposalID: proposal.id, source: proposal.source, mode: settings.mode, summaries: [text], approvedBy: "console", snapshotID: nil))
            }
            return .denied(reasons: [text])
        }
        do {
            var out = try await executor.submit(proposal, approved: approved)
            // 제안 모드·한도 초과: 승인 시트를 띄우고, 승인되면 여기서 실제로 적용한다.
            // (예전에는 화면이 시트만 띄우고 승인 결과를 아무도 적용하지 않았다.)
            if case .awaitingApproval(let resolved, let reasons) = out {
                if await requestApproval(resolved, reasons: reasons) {
                    out = try await executor.submit(resolved, approved: true)
                } else {
                    out = .denied(reasons: ["승인하지 않아 적용하지 않았습니다."])
                }
            }
            await refreshState()
            return out
        } catch { lastError = "\(error)"; await refreshState(); return nil }
    }

    // MARK: 승인

    private func requestApproval(_ p: ChangeProposal, reasons: [String]) async -> Bool {
        // 이미 떠 있는 승인 요청이 있으면 거절로 끝내고 새 요청을 띄운다 (기다리는 쪽이 영원히 멈추지 않게).
        approvalContinuation?.resume(returning: false)
        approvalContinuation = nil
        return await withCheckedContinuation { cont in
            approvalContinuation = cont
            pendingApproval = PendingApproval(proposal: p, reasons: reasons)
        }
    }

    func resolveApproval(_ ok: Bool) {
        pendingApproval = nil
        approvalContinuation?.resume(returning: ok)
        approvalContinuation = nil
        Task { await refreshState() }
    }

    /// 승인 시트를 버튼 없이 쓸어내려 닫은 경우: 거절로 처리한다.
    func approvalSheetDismissed() {
        guard pendingApproval == nil, approvalContinuation != nil else { return }
        resolveApproval(false)
    }

    // MARK: 측정

    func newMeasurementSession() {
        currentSession = MeasurementSession(venueName: settings.venue.name, microphone: settings.microphone, sweep: settings.sweep, target: settings.target, autoEQOptions: settings.autoEQ)
    }

    func prepareAudio() {
        #if canImport(AVFoundation)
        do { audioInfo = try audio.prepare() } catch { lastError = "\(error)"; audioInfo = nil }
        #endif
    }

    /// 입력 장치 목록 갱신 (UMIK-1 이 있으면 자동 선택).
    func refreshInputDevices() {
        inputDevices = AudioDevices.inputs()
        if selectedInputDevice == nil || !inputDevices.contains(where: { $0.id == selectedInputDevice?.id }) {
            selectedInputDevice = inputDevices.first { $0.looksLikeUMIK } ?? inputDevices.first { $0.isDefault } ?? inputDevices.first
            if let d = selectedInputDevice, d.looksLikeUMIK, settings.microphone == .simulated { settings.microphone = .umik1; saveSettings() }
        }
    }

    func selectInputDevice(_ d: AudioInputDevice) {
        selectedInputDevice = d
        #if canImport(AVFoundation)
        do { try audio.selectInput(d); audioInfo = try audio.prepare() } catch { lastError = "\(error)" }
        #endif
    }

    /// 측정 전 입력 레벨 확인 (RMS/피크, 클립).
    func startInputMeter() async {
        guard !isLevelMonitoring else { return }
        #if canImport(AVFoundation)
        guard await MeasurementAudioEngine.requestPermission() else { lastError = "\(AudioEngineError.permissionDenied)"; return }
        do {
            if let d = selectedInputDevice { try audio.selectInput(d) }
            audioInfo = try audio.prepare()
            try audio.startMonitoring { [weak self] samples, _ in
                let lvl = InputLevel.measure(samples)
                Task { @MainActor in self?.inputLevel = lvl }
            }
            isLevelMonitoring = true
        } catch { lastError = "\(error)" }
        #endif
    }

    func stopInputMeter() {
        #if canImport(AVFoundation)
        audio.stopMonitoring()
        #endif
        isLevelMonitoring = false
        inputLevel = nil
    }

    func togglePinkNoise() {
        #if canImport(AVFoundation)
        if isPlayingNoise { audio.stopPlayback(); isPlayingNoise = false; return }
        do { try audio.playPinkNoise(); isPlayingNoise = true } catch { lastError = "\(error)" }
        #endif
    }

    func measurePosition(named name: String) async {
        guard !isMeasuring else { return }
        isMeasuring = true; lastError = nil
        measureStatus = "스윕 재생·녹음 중…"
        defer { isMeasuring = false; measureStatus = "" }
        var spec = currentSession.sweep
        let mic = currentSession.microphone
        do {
            let recorded: [Double]
            if mic == .simulated {
                spec.sampleRate = 48_000
                var room = SimulatedRoom(seed: 11)
                if isVerificationMode, let applied = currentSession.iterations.last?.filters {
                    // 가상 방에 적용된 보정 필터를 반영 (실제 믹서 EQ 역할)
                    room.modes += applied.map { SimulatedRoom.Mode(type: .peaking, hz: $0.frequencyHz, gainDB: $0.gainDB, q: $0.q) }
                }
                let position = (isVerificationMode ? verificationPositions.count : currentSession.positions.count) + 1
                let localSpec = spec
                recorded = await Task.detached(priority: .userInitiated) { room.simulateRecording(spec: localSpec, position: position) }.value
            } else {
                #if canImport(AVFoundation)
                guard await MeasurementAudioEngine.requestPermission() else { throw AudioEngineError.permissionDenied }
                if let d = selectedInputDevice { try audio.selectInput(d) }
                if isLevelMonitoring { stopInputMeter() }
                let (rec, used) = try await audio.runSweep(spec)
                recorded = rec; spec = used
                #else
                throw AudioEngineError.unavailable("AVFoundation 없음")
                #endif
            }
            measureStatus = "임펄스 응답 계산 중…"
            let reference = SweepGenerator.sweep(spec)
            let cal = (mic == .umik1) ? calibration : nil
            let localSpec = spec
            let result: (FrequencyResponse, Double) = await Task.detached(priority: .userInitiated) {
                var opt = Deconvolution.Options(); opt.bandLimit = 15...min(20_000, localSpec.sampleRate / 2 * 0.95)
                let ir = Deconvolution.impulseResponse(recorded: recorded, reference: reference, sampleRate: localSpec.sampleRate, options: opt)
                var resp = FrequencyResponse.fromLinear(TransferFunction.magnitudeSpectrum(ir))
                if let cal { resp = cal.apply(to: resp) }
                return (resp, ir.peakTimeSeconds * 1000)
            }.value
            let pm = PositionMeasurement(name: name, response: result.0, irPeakTimeMs: result.1, microphone: mic)
            if isVerificationMode {
                verificationPositions.append(pm)
                if verificationPositions.count >= max(1, currentSession.positions.count) { await finishVerification() }
            } else {
                currentSession.positions.append(pm)
                currentSession.recompute()
                await persistSession()
            }
        } catch {
            lastError = "\(error)"
        }
    }

    func removePosition(_ id: UUID) async {
        currentSession.positions.removeAll { $0.id == id }
        currentSession.recompute()
        await persistSession()
    }

    func recompute() async {
        currentSession.target = settings.target
        currentSession.autoEQOptions = settings.autoEQ
        currentSession.recompute()
        await persistSession()
    }

    private func persistSession() async {
        guard !currentSession.positions.isEmpty else { return }
        await store.save(currentSession)
        sessions = await store.sessions
        if let r = currentSession.result {
            await toolExecutor.setMeasurement(MeasurementSummary.from(r, positions: currentSession.positions.count, microphone: currentSession.microphone.displayName, feedback: feedbackCandidates))
        }
        if peerLink.isActive { peerLink.broadcast(.measurement(currentSession)) }
    }

    func openSession(_ s: MeasurementSession) { currentSession = s }

    /// 보정 EQ 를 메인 출력에 적용하는 변경안 (사람 승인 뒤 적용).
    func markApplied() async { currentSession.appliedToMixer = true; await persistSession() }

    /// 적용 뒤 '검증 측정' 시작: 이번 회차를 기록하고, 이후 측정은 검증 목록에 쌓인다.
    func beginVerification() {
        guard let r = currentSession.result else { return }
        let it = TuningIteration(index: currentSession.iterations.count + 1, filters: r.filters, predictedRMSDB: r.residualRMSDB)
        currentSession.iterations.append(it)
        verificationPositions = []
        tuningVerdict = nil
        isVerificationMode = true
    }

    func cancelVerification() {
        if let last = currentSession.iterations.last, last.verifiedRMSDB == nil { currentSession.iterations.removeLast() }
        isVerificationMode = false; verificationPositions = []
    }

    /// 검증 측정 평균으로 판정한다.
    func finishVerification() async {
        guard isVerificationMode, let r = currentSession.result, !verificationPositions.isEmpty,
              let avg = FrequencyResponse.spatialAverage(verificationPositions.map(\.response)),
              var it = currentSession.iterations.last else { isVerificationMode = false; return }
        let previous = currentSession.iterations.count >= 2 ? currentSession.iterations[currentSession.iterations.count - 2] : nil
        let verdict = TuningLoop.verify(iteration: &it, verified: avg, target: currentSession.target, predicted: r.predicted,
                                        autoEQ: currentSession.autoEQOptions, excludedDips: r.excludedDips, previous: previous, options: TuningLoopOptions())
        currentSession.iterations[currentSession.iterations.count - 1] = it
        currentSession.verification = it.verifiedResponse
        // 관찰한 모델 오차(실측−예상)를 다음 계산에 반영
        if let v = it.verifiedResponse {
            let err = v.subtracting(r.predicted)
            currentSession.modelCorrection = (currentSession.modelCorrection?.adding(err) ?? err).smoothed(fractionOfOctave: 3)
        }
        tuningVerdict = verdict
        isVerificationMode = false
        await persistSession()
    }

    /// 다음 회차: 모델 보정을 반영해 다시 계산 (결과는 보정 탭에 새 필터로 나온다)
    func nextIteration() async {
        currentSession.recompute()
        tuningVerdict = nil
        await persistSession()
    }

    /// 변경안을 콘솔 아이패드(다른 튠메이트 기기)로 지시 카드로 보낸다. 연결이 없으면 이 기기 지시함에 보관.
    @discardableResult
    func sendInstruction(_ proposal: ChangeProposal) -> String {
        let ins = Instruction.from(proposal: proposal, state: mixerState, sender: peerLink.deviceName)
        if peerLink.send(ins) { return "지시를 보냈습니다: \(peerLink.lastEvent)" }
        peerLink.keepLocally(ins)
        return "연결된 기기가 없어 이 기기의 지시함에 보관했습니다."
    }
    @discardableResult
    func sendInstruction(assignments: [EQAssignment]) -> String {
        let ins = Instruction.from(assignments: assignments, sender: peerLink.deviceName)
        if peerLink.send(ins) { return "지시를 보냈습니다: \(peerLink.lastEvent)" }
        peerLink.keepLocally(ins)
        return "연결된 기기가 없어 이 기기의 지시함에 보관했습니다."
    }

    func exportReport() -> URL? {
        let dir = AppStore.defaultRoot().appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmm"
        let url = dir.appendingPathComponent("tunemate-report-\(df.string(from: currentSession.createdAt)).md")
        let md = MeasurementReport.markdown(currentSession, venue: settings.venue, mixer: settings.mixerModel, iterations: currentSession.iterations, verdict: tuningVerdict)
        do { try md.write(to: url, atomically: true, encoding: .utf8); return url } catch { lastError = "\(error)"; return nil }
    }

    func autoEQProposal() -> ChangeProposal? {
        guard let r = currentSession.result, !r.filters.isEmpty else { return nil }
        let bands = r.filters.enumerated().map { MixerChange.eqBand(target: .mainLR, band: $0.offset + 1, frequencyHz: $0.element.frequencyHz, gainDB: $0.element.gainDB, q: $0.element.q, on: true) }
        return ChangeProposal(source: .autoEQ, rationale: String(format: "공간 보정 EQ %d밴드 (RMS %.1f → %.1f dB)", r.filters.count, r.initialRMSDB, r.residualRMSDB), changes: bands)
    }

    func exportSweepWAV() -> URL? {
        let dir = AppStore.defaultRoot().appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tunemate-sweep-\(Int(settings.sweep.sampleRate))Hz-\(Int(settings.sweep.durationSeconds))s.wav")
        do { try WAVWriter.write(samples: SweepGenerator.playbackSignal(settings.sweep), sampleRate: settings.sweep.sampleRate, to: url); return url } catch { lastError = "\(error)"; return nil }
    }

    // MARK: 하울링

    func startFeedbackMonitor() {
        guard !isMonitoring else { return }
        detector.reset(); feedbackCandidates = []
        detector.options = settings.feedback
        isMonitoring = true
        if settings.microphone == .simulated {
            // 시뮬레이션: 잡음 + 커지는 톤
            let rta = RealTimeAnalyzer(sampleRate: 48_000, fftSize: 8192, averaging: 0.3)
            self.rta = rta
            Task { [weak self] in
                var rng = SplitMix64(seed: 5); var k = 0
                while let self, self.isMonitoring {
                    k += 1
                    let phase = k % 60   // 15프레임 잡음 → 30프레임 커지는 톤 → 잠잠
                    let tone = (phase > 15 && phase < 45) ? Decibel.toAmplitude(-40 + Double(min(phase - 15, 16)) * 1.2) : 0
                    let block = (0..<8192).map { i in 0.01 * (rng.nextUniform() * 2 - 1) + tone * sin(2 * Double.pi * 2_480 * Double(i) / 48_000) }
                    let frame = rta.analyze(block)
                    self.liveSpectrum = frame.response
                    self.feedbackCandidates = self.detector.process(frame)
                    self.handleCandidates(self.feedbackCandidates)
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
            }
            return
        }
        #if canImport(AVFoundation)
        do {
            let info = try audio.prepare()
            audioInfo = info
            let rta = RealTimeAnalyzer(sampleRate: info.inputSampleRate, fftSize: 8192, averaging: 0.3)
            self.rta = rta
            try audio.startMonitoring { [weak self] samples, _ in
                let frames = rta.push(samples)
                guard let last = frames.last else { return }
                let cands = self?.detector.process(last) ?? []
                Task { @MainActor in self?.liveSpectrum = last.response; self?.feedbackCandidates = cands; self?.handleCandidates(cands) }
            }
        } catch { lastError = "\(error)"; isMonitoring = false }
        #endif
    }

    /// 후보가 갱신될 때마다 호출: 링아웃 기록, 자동 억제.
    private func handleCandidates(_ cands: [FeedbackCandidate]) {
        if ringOut != nil { for c in cands where c.confidence >= 0.5 { ringOut?.register(c) } }
        if peerLink.isActive, !cands.isEmpty { peerLink.broadcast(.feedback(cands, from: peerLink.deviceName)) }
        let effectiveMode = remoteConsole?.mode ?? settings.mode
        let hasMixer = connectionStatus == .connected || remoteConsole != nil
        guard autoSuppress, effectiveMode == .rehearsalAuto, hasMixer, !isSuppressing,
              let pick = suppressor.pick(from: cands) else { return }
        let state = mixerState ?? remoteConsole?.state ?? MockMixerDriver.defaultState(model: settings.mixerModel)
        guard let (proposal, target, band, gain) = suppressor.proposal(for: pick, channel: ringOut?.channel, state: state, policy: settings.policy.notch) else {
            suppressionEvents = suppressor.events; return
        }
        isSuppressing = true
        Task {
            let out = await submit(proposal)
            let text: String
            switch out {
            case .applied?: text = "적용"
            case .awaitingApproval?: text = "승인 대기"
            case .denied(let r)?: text = "거절: " + r.joined(separator: " ")
            case nil: text = "오류"
            }
            suppressor.record(frequencyHz: pick.frequencyHz, target: target, band: band, gainDB: gain, outcome: text)
            suppressionEvents = suppressor.events
            isSuppressing = false
        }
    }

    func startRingOut(channel: Int?) { ringOut = RingOutSession(channel: channel); if !isMonitoring { startFeedbackMonitor() } }
    func stopRingOut() { ringOut = nil }
    func ringOutProposal() -> (ChangeProposal?, [String]) {
        guard let r = ringOut else { return (nil, []) }
        return r.proposal(state: mixerState ?? remoteConsole?.state ?? MockMixerDriver.defaultState(model: settings.mixerModel), policy: settings.policy.notch)
    }
    func resetSuppressor() { suppressor.reset(); suppressionEvents = [] }

    func stopFeedbackMonitor() {
        isMonitoring = false
        #if canImport(AVFoundation)
        audio.stopMonitoring()
        #endif
    }

    /// 후보 → 노치 변경안
    func notchProposal(for c: FeedbackCandidate, channel: Int?) -> ChangeProposal? {
        let state = mixerState ?? remoteConsole?.state ?? MockMixerDriver.defaultState(model: settings.mixerModel)
        let chEQ = channel.flatMap { state.channel($0)?.eq }
        let plan = NotchPlanner.plan(frequencyHz: c.frequencyHz, channel: channel.map { .channel($0) }, channelEQ: chEQ, mainEQ: state.main?.eq ?? [], policy: settings.policy.notch)
        switch plan {
        case .newBand(let t, let b, let f):
            return ChangeProposal(source: .feedbackSuppressor, rationale: String(format: "하울링 %.0f Hz 억제 노치", c.frequencyHz), changes: [.eqBand(target: t, band: b, frequencyHz: f.frequencyHz, gainDB: f.gainDB, q: f.q, on: true)])
        case .deepenBand(let t, let b, let g):
            let cur = state.eq(of: t)?.first { $0.index == b }
            return ChangeProposal(source: .feedbackSuppressor, rationale: String(format: "하울링 %.0f Hz 노치 깊게", c.frequencyHz), changes: [.eqBand(target: t, band: b, frequencyHz: cur?.frequencyHz ?? c.frequencyHz, gainDB: g, q: cur?.q ?? settings.policy.notch.q, on: true)])
        case .noBandAvailable(let advice), .depthLimitReached(_, _, let advice):
            lastError = advice; return nil
        }
    }

    // MARK: AI

    func apiKey(_ p: AIProviderKind) -> String { secrets.get(ProviderFactory.keyName(p)) ?? "" }
    func setAPIKey(_ p: AIProviderKind, _ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { secrets.delete(ProviderFactory.keyName(p)) } else { try? secrets.set(ProviderFactory.keyName(p), k) }
        objectWillChange.send()
    }

    var context: AssistantContext {
        let rc = remoteConsole
        return AssistantContext(venue: settings.venue, mode: rc?.mode ?? settings.mode, mixerModel: rc?.model ?? settings.mixerModel,
                         measurement: currentSession.result.map { MeasurementSummary.from($0, positions: currentSession.positions.count, microphone: currentSession.microphone.displayName, feedback: feedbackCandidates) })
    }

    func sendChat(_ text: String, tier: ModelTier? = nil) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !isThinking else { return }
        isThinking = true; lastError = nil
        defer { isThinking = false }
        do {
            let provider = try ProviderFactory(secrets: secrets).make(settings.provider)
            let useTier = tier ?? settings.chatTier
            let model = settings.catalog.model(settings.provider, useTier)
            let effort: LLMRequest.Effort = useTier == .precise ? .high : (useTier == .standard ? .medium : .low)
            _ = try await session.send(t, provider: provider, model: model, context: context, effort: effort)
        } catch {
            lastError = "\(error)"
        }
        chatTurns = await session.turns
        usage = await session.totalUsage
        await refreshState()
    }

    func analyzeMeasurementWithAI() async {
        await sendChat(AssistantSession.measurementAnalysisPrompt(), tier: settings.analysisTier)
    }

    func resetChat() async { await session.reset(); chatTurns = []; usage = LLMUsage() }
}
