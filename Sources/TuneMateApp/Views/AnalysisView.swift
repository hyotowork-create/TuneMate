import SwiftUI
import TuneMateCore

struct AnalysisView: View {
    @EnvironmentObject var model: AppModel
    @State private var outcomeText = ""

    var body: some View {
        Page(title: "보정") {
            ErrorBanner()
            if let r = model.currentSession.result {
                SectionCard(title: "측정 vs 목표 vs 예상") {
                    ResponseChart(series: [("측정(정렬)", r.measured), ("목표", r.target), ("EQ 적용 예상", r.predicted)])
                    KeyValueRow(key: "목표 대비 RMS 오차", value: String(format: "%.1f dB → %.1f dB", r.initialRMSDB, r.residualRMSDB), valueColor: .green)
                    Picker("목표 곡선", selection: $model.settings.target) {
                        Text("평탄").tag(TargetCurve.flat); Text("설교 중심").tag(TargetCurve.speech); Text("찬양 중심").tag(TargetCurve.worshipMusic)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Stepper("밴드 수 \(model.settings.autoEQ.maxFilters)", value: $model.settings.autoEQ.maxFilters, in: 1...12)
                        Button("다시 계산") { model.saveSettings(); Task { await model.recompute() } }.buttonStyle(.bordered)
                    }
                    // 연결된 믹서의 메인 EQ 밴드 수보다 많이 계산했으면 적용이 막히므로 미리 알려 준다.
                    if model.connectionStatus == .connected, let n = model.mixerState?.eq(of: .mainLR)?.count, n > 0, r.filters.count > n {
                        AdaptiveStack {
                            InfoNote(text: "이 믹서의 메인 EQ는 \(n)밴드입니다. 지금 보정값은 \(r.filters.count)밴드라 믹서에 적용할 수 없습니다.", tint: .orange)
                            Button("믹서에 맞추기 (\(n)밴드)") { model.settings.autoEQ.maxFilters = n; model.saveSettings(); Task { await model.recompute() } }.buttonStyle(.bordered)
                        }
                    }
                }
                SectionCard(title: "보정값", subtitle: "대상 출력 · 밴드 · 주파수 · 게인 · Q — 공식 앱에 그대로 입력") {
                    let rows = EQAssignment.fromResult(r)
                    if rows.isEmpty { InfoNote(text: "보정이 필요한 편차가 없습니다 (±1 dB 이내).") }
                    else {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                            GridRow { Text("대상").bold(); Text("밴드").bold(); Text("주파수").bold(); Text("게인").bold(); Text("Q").bold() }.font(.caption)
                            Divider()
                            ForEach(rows) { a in
                                GridRow {
                                    Text(a.target); Text("\(a.band)")
                                    Text(String(format: "%.0f Hz", a.frequencyHz))
                                    Text(String(format: "%+.1f dB", a.gainDB)).foregroundStyle(a.gainDB < 0 ? .blue : .orange)
                                    Text(String(format: "%.1f", a.q))
                                }.font(.subheadline.monospacedDigit())
                            }
                        }
                    }
                    ForEach(r.notes, id: \.self) { InfoNote(text: "• " + $0) }
                    VStack(alignment: .leading, spacing: 8) {
                        Button { copy(EQAssignment.markdownTable(rows)) } label: { Label("표 복사 (공식 앱에 직접 입력)", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).disabled(rows.isEmpty)
                        Button {
                            guard let p = model.autoEQProposal() else { return }
                            Task { if let out = await model.submit(p) { await show(out) } }
                        } label: { Label(model.connectionStatus == .connected ? "믹서에 적용 (변경안)" : (model.remoteConsole != nil ? "콘솔 기기로 적용 요청" : "믹서에 적용 (변경안)"), systemImage: "arrow.right.circle").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).disabled(rows.isEmpty || (model.connectionStatus != .connected && model.remoteConsole == nil))
                        Button { outcomeText = model.shareMeasurement() } label: { Label("측정 결과를 다른 기기와 공유", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).disabled(!model.peerLink.isActive)
                        Button { outcomeText = model.sendInstruction(assignments: rows) } label: { Label(model.peerLink.peers.isEmpty ? "지시함에 넣기 (공식 앱 위에 띄우기용)" : "콘솔 기기로 지시 보내기", systemImage: "ipad.and.arrow.forward").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).disabled(rows.isEmpty)
                        Button { Task { await model.analyzeMeasurementWithAI() } } label: { Label("AI 분석 (\(model.settings.analysisTier.displayName))", systemImage: "sparkles").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).disabled(model.apiKey(model.settings.provider).isEmpty)
                    }
                    if model.connectionStatus != .connected && model.remoteConsole == nil { InfoNote(text: "믹서가 연결되지 않아 수동 적용만 가능합니다. 지시함에서 기기 연결을 켜면 콘솔 기기를 통해 적용할 수 있습니다.", tint: .orange) }
                    OutcomeText(text: outcomeText)
                }
                SectionCard(title: "검증 루프", subtitle: "적용 → 같은 위치 재측정 → 판정 (최대 3회)") {
                    if !model.currentSession.iterations.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            GridRow { Text("회차").bold(); Text("필터").bold(); Text("예상 잔차").bold(); Text("실측 잔차").bold(); Text("예상−실측").bold() }.font(.caption)
                            ForEach(model.currentSession.iterations) { it in
                                GridRow {
                                    Text("\(it.index)"); Text("\(it.filters.count)")
                                    Text(String(format: "%.1f", it.predictedRMSDB))
                                    Text(it.verifiedRMSDB.map { String(format: "%.1f dB", $0) } ?? "측정 중")
                                    Text(it.predictionErrorRMSDB.map { String(format: "%.1f", $0) } ?? "-")
                                }.font(.subheadline.monospacedDigit())
                            }
                        }
                    }
                    if let v = model.currentSession.verification, let r0 = model.currentSession.result {
                        ResponseChart(series: [("목표", r0.target), ("EQ 적용 예상", r0.predicted), ("재측정(정렬)", v)])
                    }
                    if let verdict = model.tuningVerdict {
                        InfoNote(text: verdict.displayText, tint: {
                            switch verdict { case .converged: return .green; case .improving: return .blue; default: return .orange }
                        }())
                    }
                    if model.isVerificationMode {
                        HStack {
                            Text("검증 측정 중 — \(model.verificationPositions.count)/\(model.currentSession.positions.count) 위치. 측정 탭에서 같은 위치를 다시 측정하세요.").font(.caption)
                            Spacer()
                            Button("취소") { model.cancelVerification() }.buttonStyle(.bordered).controlSize(.small)
                        }
                        Button("검증 완료 (지금까지 측정으로 판정)") { Task { await model.finishVerification() } }.buttonStyle(.bordered).disabled(model.verificationPositions.isEmpty)
                    } else {
                        AdaptiveStack {
                            Button("검증 측정 시작") { model.beginVerification() }.buttonStyle(.borderedProminent).disabled(r.filters.isEmpty || model.currentSession.iterations.count >= 3 && !(model.tuningVerdict?.shouldContinue ?? true))
                            if model.tuningVerdict?.shouldContinue == true {
                                Button("다음 회차 계산") { Task { await model.nextIteration() } }.buttonStyle(.bordered)
                            }
                            if let url = model.exportReport() {
                                ShareLink(item: url) { Label("리포트 내보내기", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
                            }
                        }
                    }
                    InfoNote(text: "세 번 반복해도 수렴하지 않으면 EQ가 아닌 원인(스피커 위치·반사)입니다. REW로 같은 위치·같은 마이크 측정을 병행해 차이가 크면 Phase 1 완료로 보지 않습니다.")
                }
            } else {
                ContentUnavailableView("측정 결과가 없습니다", systemImage: "waveform", description: Text("측정 탭에서 좌석 위치를 측정하면 보정값이 계산됩니다."))
            }
        }
    }

    func show(_ out: ExecutionOutcome) async {
        outcomeText = outcomeDescription(out)
        if case .applied = out { await model.markApplied() }
    }

    func copy(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
        outcomeText = "표를 복사했습니다."
    }
}
