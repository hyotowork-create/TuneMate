import SwiftUI
import TuneMateCore

struct MixerView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page(title: "믹서") {
            ErrorBanner()
            if let rc = model.remoteConsole { remoteConsoleCard(rc) }
            connectionCard
            modeCard
            if let s = model.mixerState { channelsCard(s); outputsCard(s) }
            snapshotsCard
            logCard
        }
    }

    // MARK: 연결
    var connectionCard: some View {
        SectionCard(title: "연결", subtitle: "믹서와 같은 Wi-Fi/LAN 에 있어야 합니다") {
            Picker("믹서 모델", selection: Binding(get: { model.settings.mixerModelName }, set: { name in
                if let m = MixerModel.known.first(where: { $0.name == name }) {
                    model.settings.mixerFamily = m.family; model.settings.mixerModelName = m.name; model.saveSettings()
                    Task { await model.rebuildDriver() }
                }
            })) {
                ForEach(MixerModel.known, id: \.name) { Text($0.displayName).tag($0.name) }
            }
            .pickerStyle(.menu)
            HStack(spacing: 6) { protocolBadge; Spacer() }
            if model.settings.mixerFamily != .mock {
                TextField("믹서 IP 주소 (예: 192.168.0.50)", text: $model.settings.mixerHost)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.decimalPad).textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
                    .onSubmit { model.saveSettings() }
            }
            AdaptiveStack {
                if model.settings.mixerFamily != .mock {
                    Button(model.isProbing ? "테스트 중…" : "연결 테스트") { model.saveSettings(); Task { await model.probeMixer() } }
                        .buttonStyle(.bordered).disabled(model.isProbing || model.settings.mixerHost.isEmpty)
                }
                Button(model.connectionStatus == .connected ? "연결 끊기" : "연결") {
                    model.saveSettings()
                    Task { model.connectionStatus == .connected ? await model.disconnectMixer() : await model.connectMixer() }
                }
                .buttonStyle(.borderedProminent).disabled(model.connectionStatus == .connecting)
                Button("새로 고침") { Task { await model.refreshState() } }.buttonStyle(.bordered).disabled(model.connectionStatus != .connected)
            }
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText).font(.caption)
            }
            if let r = model.probeResult {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(r.ok ? .green : .red)
                        Text(r.ok ? "응답 있음 — \(r.reportedModel) \(r.reportedName)" : "응답 없음").font(.subheadline)
                    }
                    if r.ok {
                        KeyValueRow(key: "모델", value: r.model?.displayName ?? r.reportedModel)
                        if let fw = r.firmware { KeyValueRow(key: "펌웨어", value: fw) }
                        if let ms = r.roundTripMs { KeyValueRow(key: "왕복 시간", value: String(format: "%.0f ms", ms)) }
                        KeyValueRow(key: "포트", value: "\(r.port)")
                    }
                    InfoNote(text: r.message, tint: r.ok ? .secondary : .orange)
                }
                .padding(10).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            Divider()
            Button(model.isDiscovering ? "탐색 중…" : "네트워크에서 믹서 찾기") { Task { await model.discoverMixers() } }
                .buttonStyle(.bordered).disabled(model.isDiscovering)
            InfoNote(text: "X32/M32·X-Air/MR 은 OSC 브로드캐스트(10023·10024)로, Yamaha 는 입력한 IP 로 RCP 확인, DM24.8 은 명세 포트 확정 뒤 탐색합니다. 탐색이 안 되면 위 '연결 테스트'로 IP 를 직접 확인하세요.")
            ForEach(model.discovered) { d in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(d.reportedName) · \(d.model.displayName)").font(.subheadline)
                        Text("\(d.host)\(d.firmware.map { " · fw \($0)" } ?? "") · \(d.method) · 신뢰도 \(Int(d.confidence * 100))%").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("선택") { Task { await model.select(d) } }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            if model.discovered.isEmpty && !model.isDiscovering { InfoNote(text: "찾은 믹서 없음") }
        }
    }

    func remoteConsoleCard(_ rc: ConsoleStatus) -> some View {
        SectionCard(title: "콘솔 기기 경유", subtitle: "이 기기는 믹서에 직접 연결되지 않았지만, 연결된 기기를 통해 적용할 수 있습니다") {
            KeyValueRow(key: "콘솔 기기", value: rc.deviceName, valueColor: .green)
            KeyValueRow(key: "믹서", value: rc.model.displayName)
            KeyValueRow(key: "콘솔 운영 모드", value: rc.mode.displayName)
            KeyValueRow(key: "상태 공유", value: rc.state.map { "\($0.channels.count)채널 · \($0.capturedAt.formatted(date: .omitted, time: .shortened))" } ?? "없음")
            InfoNote(text: "변경안을 적용하면 콘솔 기기로 보내지고, 그쪽 안전 한도와 승인을 거친 뒤 결과가 돌아옵니다.")
            if !model.lastRemoteResult.isEmpty { OutcomeText(text: model.lastRemoteResult) }
        }
    }

    var modeCard: some View {
        SectionCard(title: "운영 모드") {
            Picker("모드", selection: $model.settings.mode) { ForEach(OperatingMode.allCases) { Text($0.displayName.replacingOccurrences(of: " 모드", with: "")).tag($0) } }
                .pickerStyle(.segmented)
                .onChange(of: model.settings.mode) { _, _ in model.saveSettings() }
            InfoNote(text: model.settings.mode.explanation)
            Toggle("이 기기를 콘솔로 사용 (다른 기기의 변경안을 받아 적용)", isOn: $model.actAsConsole)
                .onChange(of: model.actAsConsole) { _, v in model.settings.actAsConsole = v; model.saveSettings(); model.broadcastConsoleStatus() }
            Toggle("앱 시작 시 이 믹서에 자동 연결", isOn: $model.settings.autoConnectMixer).onChange(of: model.settings.autoConnectMixer) { _, _ in model.saveSettings() }
            Button("마지막 변경 되돌리기") { Task { await model.undoLast() } }.buttonStyle(.bordered).disabled(model.connectionStatus != .connected)
            InfoNote(text: "모든 변경 직전에 자동 스냅샷이 남습니다.")
        }
    }

    func channelsCard(_ s: MixerState) -> some View {
        SectionCard(title: "채널", subtitle: "페이더 · 뮤트 · 프리앰프 · EQ 사용 밴드 · 레벨") {
            ForEach(s.channels.prefix(32)) { c in
                HStack(spacing: 8) {
                    Text("\(c.index)").font(.caption.monospacedDigit()).frame(width: 24, alignment: .trailing)
                    Text(c.name.isEmpty ? (model.settings.venue.channelLabels[c.index] ?? "—") : c.name).font(.subheadline).lineLimit(1).frame(minWidth: 60, alignment: .leading)
                    Spacer(minLength: 4)
                    Text(String(format: "%.1f", c.faderDB)).font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
                    Image(systemName: c.muted ? "speaker.slash.fill" : "speaker.wave.2").foregroundStyle(c.muted ? .red : .secondary).frame(width: 18)
                    Text(String(format: "%.0f%@", c.preampGainDB, c.phantomOn ? "⚡︎" : "")).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    Text("EQ \(c.eq.filter { $0.enabled && abs($0.gainDB) >= 0.05 }.count)").font(.caption2).foregroundStyle(.secondary).frame(width: 34)
                    LevelBar(db: model.levels?.channelsDB[safe: c.index - 1]).frame(width: 50)
                }
                .padding(.vertical, 1)
            }
        }
    }

    func outputsCard(_ s: MixerState) -> some View {
        SectionCard(title: "출력") {
            ForEach(s.outputs) { o in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(o.target.description).font(.subheadline).bold()
                        Text(o.name).font(.subheadline)
                        Spacer()
                        Text(String(format: "%.1f dB", o.faderDB)).font(.caption.monospacedDigit())
                        if o.muted { StatusPill(text: "MUTE", color: .red) }
                    }
                    let eq = o.eq.filter { $0.enabled && abs($0.gainDB) >= 0.05 }
                    if !eq.isEmpty {
                        Text(eq.map { String(format: "%.0fHz %+.1f Q%.1f", $0.frequencyHz, $0.gainDB, $0.q) }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @State private var sceneNumber = 2
    @State private var sceneName = "측정용 평탄"

    var snapshotsCard: some View {
        SectionCard(title: "스냅샷·씬", subtitle: "변경 전 자동 백업 목록. 복원은 항상 사람 확인") {
            HStack {
                Stepper("씬 번호 \(sceneNumber)", value: $sceneNumber, in: 1...99)
                TextField("씬 이름", text: $sceneName).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                Button("씬 저장") { Task { await model.saveScene(number: sceneNumber, name: sceneName) } }.buttonStyle(.bordered).disabled(model.connectionStatus != .connected)
            }
            if model.snapshots.isEmpty { InfoNote(text: "스냅샷 없음") }
            ForEach(model.snapshots.suffix(10).reversed()) { snap in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snap.takenAt.formatted(date: .abbreviated, time: .standard)).font(.caption)
                        Text(snap.reason).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("복원") { Task { await model.restoreSnapshot(snap.id) } }.buttonStyle(.bordered).controlSize(.small).disabled(model.connectionStatus != .connected)
                }
            }
        }
    }

    var logCard: some View {
        SectionCard(title: "변경 로그") {
            if model.changeLog.isEmpty { InfoNote(text: "기록 없음") }
            ForEach(model.changeLog.suffix(20).reversed()) { e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(e.timestamp.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                        StatusPill(text: "\(e.source.rawValue) · \(e.approvedBy)", color: .secondary)
                        if e.undone { StatusPill(text: "되돌림", color: .orange) }
                    }
                    Text(e.summaries.joined(separator: "; ")).font(.caption).strikethrough(e.undone)
                    if let err = e.error { Text(err).font(.caption2).foregroundStyle(.red) }
                }
                .padding(.vertical, 2)
            }
        }
    }

    var statusColor: Color {
        switch model.connectionStatus { case .connected: return .green; case .connecting: return .orange; case .failed: return .red; case .disconnected: return .gray }
    }
    var statusText: String {
        switch model.connectionStatus {
        case .disconnected: return "연결 안 됨"
        case .connecting: return "연결 중…"
        case .connected: return "연결됨" + (model.mixerState?.firmwareVersion.map { " · fw \($0)" } ?? "")
        case .failed(let e): return "실패: \(e)"
        }
    }
    @ViewBuilder var protocolBadge: some View {
        switch model.settings.mixerModel.protocolStatus {
        case .publicSpec: StatusPill(text: "공개 프로토콜", color: .green)
        case .reverseEngineered: StatusPill(text: "역분석 검증됨", color: .blue)
        case .unverified: StatusPill(text: "프로토콜 미검증 — 읽기·제안만, 쓰기 차단", color: .red)
        }
    }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
