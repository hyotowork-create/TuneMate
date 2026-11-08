import SwiftUI
import TuneMateCore

struct FeedbackView: View {
    @EnvironmentObject var model: AppModel
    @State private var channel: Int? = 1
    @State private var outcome = ""

    var body: some View {
        Page(title: "하울링") {
            ErrorBanner()
            SectionCard(title: "실시간 검출", subtitle: "내장 마이크로도 충분합니다") {
                HStack {
                    Button(model.isMonitoring ? "감시 중지" : "감시 시작") { model.isMonitoring ? model.stopFeedbackMonitor() : model.startFeedbackMonitor() }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    ModeBadge(mode: model.settings.mode)
                }
                Text(model.settings.microphone.displayName).font(.caption).foregroundStyle(.secondary)
                if let s = model.liveSpectrum { ResponseChart(series: [("입력 스펙트럼", s)], decimate: 1) }
                else { InfoNote(text: "감시를 시작하면 입력 스펙트럼이 표시됩니다.") }
            }
            SectionCard(title: "하울링 후보") {
                if model.feedbackCandidates.isEmpty { InfoNote(text: "후보 없음") }
                ForEach(model.feedbackCandidates) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(String(format: "%.0f Hz", c.frequencyHz)).font(.title3).bold()
                            Spacer()
                            StatusPill(text: String(format: "신뢰도 %.0f%%", c.confidence * 100), color: c.confidence > 0.7 ? .red : .orange)
                        }
                        Text(String(format: "돌출 %.0f dB · 증가 %.1f dB · %d프레임", c.prominenceDB, c.growthDB, c.persistenceFrames)).font(.caption).foregroundStyle(.secondary)
                        AdaptiveStack {
                            Picker("채널", selection: $channel) {
                                Text("채널 모름 → 메인 EQ").tag(Int?.none)
                                ForEach(1...model.settings.mixerModel.channelCount, id: \.self) { n in
                                    Text("CH\(n) \(model.settings.venue.channelLabels[n] ?? "")").tag(Int?.some(n))
                                }
                            }
                            .pickerStyle(.menu)
                            Button("노치 \(Int(model.settings.policy.notch.stepDB)) dB 적용") {
                                guard let p = model.notchProposal(for: c, channel: channel) else { return }
                                Task { if let out = await model.submit(p) { show(out) } }
                            }
                            .buttonStyle(.borderedProminent).disabled(model.connectionStatus != .connected && model.remoteConsole == nil)
                            Button("지시 보내기") {
                                guard let p = model.notchProposal(for: c, channel: channel) else { return }
                                outcome = model.sendInstruction(p)
                            }.buttonStyle(.bordered)
                        }
                    }
                    .padding(10).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
                if model.connectionStatus != .connected && !model.feedbackCandidates.isEmpty { InfoNote(text: "믹서 미연결: 주파수를 보고 공식 앱에서 노치를 거세요.", tint: .orange) }
                OutcomeText(text: outcome)
            }
            SectionCard(title: "자동 억제", subtitle: "리허설 자동 모드에서만 동작 · 한도 안의 노치를 바로 적용") {
                Toggle("후보가 확정되면 자동으로 노치 적용", isOn: $model.autoSuppress)
                if model.autoSuppress && model.settings.mode != .rehearsalAuto { InfoNote(text: "지금은 \(model.settings.mode.displayName)라 적용하지 않습니다. 믹서 탭에서 리허설 자동 모드로 바꾸세요.", tint: .orange) }
                if model.autoSuppress && model.connectionStatus != .connected && model.remoteConsole == nil { InfoNote(text: "믹서가 연결되지 않았습니다.", tint: .orange) }
                if model.autoSuppress && model.connectionStatus != .connected && model.remoteConsole != nil { InfoNote(text: "콘솔 기기(\(model.remoteConsole!.deviceName))를 통해 적용합니다.") }
                ForEach(model.suppressionEvents.suffix(8).reversed()) { e in
                    HStack {
                        Text(e.at.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                        Text(String(format: "%.0f Hz → %@ %d밴드 %+.0f dB", e.frequencyHz, e.target.description, e.band, e.gainDB)).font(.caption)
                        Spacer()
                        StatusPill(text: e.outcome, color: e.outcome == "적용" ? .green : (e.outcome.hasPrefix("거절") || e.outcome.hasPrefix("불가") ? .red : .orange))
                    }
                }
                if !model.suppressionEvents.isEmpty { Button("기록 지우기") { model.resetSuppressor() }.font(.caption) }
            }
            SectionCard(title: "링아웃 (리허설 전)", subtitle: "게인을 천천히 올리며 먼저 우는 주파수를 모아 한 번에 노치") {
                if let r = model.ringOut {
                    HStack {
                        Text("기록 중 · \(r.hits.count)곳" + (r.channel.map { " · CH\($0)" } ?? " · 메인 EQ")).font(.subheadline)
                        Spacer()
                        Button("중지") { model.stopRingOut() }.buttonStyle(.bordered).controlSize(.small)
                    }
                    ForEach(r.hits.sorted { $0.prominenceDB > $1.prominenceDB }) { h in
                        HStack { Text(String(format: "%.0f Hz", h.frequencyHz)).font(.subheadline.monospacedDigit()); Spacer(); Text(String(format: "돌출 %.0f dB", h.prominenceDB)).font(.caption).foregroundStyle(.secondary) }
                    }
                    Button("기록한 주파수 전부 노치 (변경안)") {
                        let (p, notes) = model.ringOutProposal()
                        if !notes.isEmpty { outcome = notes.joined(separator: " / ") }
                        guard let p else { return }
                        Task { if let out = await model.submit(p) { show(out) } }
                    }
                    .buttonStyle(.borderedProminent).disabled(r.hits.isEmpty || (model.connectionStatus != .connected && model.remoteConsole == nil))
                } else {
                    AdaptiveStack {
                        Picker("채널", selection: $channel) {
                            Text("채널 모름 → 메인 EQ").tag(Int?.none)
                            ForEach(1...model.settings.mixerModel.channelCount, id: \.self) { n in Text("CH\(n) \(model.settings.venue.channelLabels[n] ?? "")").tag(Int?.some(n)) }
                        }.pickerStyle(.menu)
                        Button("링아웃 시작") { model.startRingOut(channel: channel) }.buttonStyle(.borderedProminent)
                    }
                }
                InfoNote(text: "보컬 마이크 게인을 천천히 올려 하울링이 먼저 나는 주파수를 찾고 미리 노치를 걸어 둡니다. 노치는 한 번에 \(Int(model.settings.policy.notch.stepDB)) dB, 최대 \(Int(model.settings.policy.notch.maxDepthDB)) dB. 한도에 닿으면 게인을 낮추거나 마이크·스피커 위치를 조정하세요.")
            }
        }
    }

    func show(_ out: ExecutionOutcome) {
        outcome = outcomeDescription(out)
        if case .awaitingApproval(let p, let r) = out { model.pendingApproval = AppModel.PendingApproval(proposal: p, reasons: r) }
    }
}
