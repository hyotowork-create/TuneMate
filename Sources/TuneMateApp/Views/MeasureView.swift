import SwiftUI
import TuneMateCore

struct MeasureView: View {
    @EnvironmentObject var model: AppModel
    @State private var positionName = ""
    @State private var showChecklist = false
    @State private var exportMessage = ""

    var body: some View {
        Page(title: "측정") {
            ErrorBanner()
            if model.isVerificationMode {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.seal").foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("검증 측정 \(model.currentSession.iterations.count)회차 — \(model.verificationPositions.count)/\(model.currentSession.positions.count) 위치").font(.subheadline).bold()
                        Text("보정을 적용한 상태에서 같은 위치를 같은 순서로 다시 측정하세요. 다 채우면 자동으로 판정합니다.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("판정") { Task { await model.finishVerification() } }.buttonStyle(.bordered).controlSize(.small).disabled(model.verificationPositions.isEmpty)
                }
                .padding(10).background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            deviceCard
            signalCard
            positionsCard
            if let avg = model.currentSession.average { chartCard(avg) }
            if !model.sessions.isEmpty { savedCard }
        }
        .sheet(isPresented: $showChecklist) { ChecklistSheet() }
        .onAppear { if model.inputDevices.isEmpty { model.refreshInputDevices() } }
        .onDisappear { if model.isLevelMonitoring { model.stopInputMeter() } }
    }

    // MARK: 장치
    var deviceCard: some View {
        SectionCard(title: "입력 장치", subtitle: "UMIK-1 을 USB-C 로 꽂으면 목록에 나타납니다") {
            Picker("마이크 종류", selection: $model.currentSession.microphone) {
                ForEach(MicrophoneKind.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            if model.currentSession.microphone == .builtIn { InfoNote(text: BuiltInMicPolicy.note, tint: .orange) }
            if model.currentSession.microphone != .simulated {
                if model.inputDevices.isEmpty {
                    InfoNote(text: "입력 장치를 찾지 못했습니다. 마이크 연결 후 '다시 찾기'.", tint: .orange)
                } else {
                    ForEach(model.inputDevices) { d in
                        Button { model.selectInputDevice(d) } label: {
                            HStack {
                                Image(systemName: model.selectedInputDevice?.id == d.id ? "largecircle.fill.circle" : "circle")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(d.name).font(.subheadline)
                                    Text("\(d.kind) · \(Int(d.sampleRate)) Hz · \(d.channels)ch\(d.isDefault ? " · 기본" : "")").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if d.looksLikeUMIK { StatusPill(text: "UMIK", color: .green) }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                AdaptiveStack {
                    Button("다시 찾기") { model.refreshInputDevices() }
                    Button(model.isLevelMonitoring ? "입력 확인 중지" : "입력 확인 (레벨)") {
                        Task { model.isLevelMonitoring ? model.stopInputMeter() : await model.startInputMeter() }
                    }
                }
                .buttonStyle(.bordered)
                if let lvl = model.inputLevel {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("입력 레벨").font(.caption); Spacer(); Text(String(format: "RMS %.0f · 피크 %.0f dBFS", lvl.rmsDB, lvl.peakDB)).font(.caption.monospacedDigit()) }
                        LevelBar(db: lvl.rmsDB)
                        InfoNote(text: lvl.advice, tint: lvl.clipped ? .red : (lvl.rmsDB < -40 ? .orange : .green))
                    }
                }
                if model.currentSession.microphone == .umik1 {
                    HStack(spacing: 6) {
                        Image(systemName: model.calibration == nil ? "xmark.circle" : "checkmark.circle.fill").foregroundStyle(model.calibration == nil ? .orange : .green)
                        Text(model.calibration == nil ? "보정 파일 미등록 — 설정에서 붙여넣기" : "보정 파일 적용 (시리얼 \(model.calibration?.serialNumber ?? "-"))").font(.caption)
                    }
                }
            } else {
                InfoNote(text: "장비 없이 가상 예배당으로 전체 흐름을 봅니다. 실제 측정은 마이크 종류를 UMIK-1 으로 바꾸세요.")
            }
        }
    }

    // MARK: 신호
    var signalCard: some View {
        SectionCard(title: "테스트 신호") {
            let s = model.currentSession.sweep
            KeyValueRow(key: "스윕", value: String(format: "%.0f–%.0f Hz · %.0f초 · −%.0f dBFS", s.startHz, s.endHz, s.durationSeconds, -Decibel.fromAmplitude(s.amplitude)))
            InfoNote(text: "Mac: 헤드폰 출력 → 믹서 라인 입력. iPhone·iPad: USB-C 허브 + 오디오 출력, 또는 아래 WAV 를 믹서 USB 로 재생.")
            AdaptiveStack {
                Button("스윕 WAV 내보내기") { if let u = model.exportSweepWAV() { exportMessage = "저장: \(u.path)" } }
                if model.currentSession.microphone != .simulated {
                    Button(model.isPlayingNoise ? "핑크노이즈 중지" : "핑크노이즈 재생") { model.togglePinkNoise() }
                }
                Button("현장 체크리스트") { showChecklist = true }
            }
            .buttonStyle(.bordered)
            OutcomeText(text: exportMessage)
        }
    }

    // MARK: 위치 측정
    var positionsCard: some View {
        SectionCard(title: "좌석 위치 측정", subtitle: "5~8곳 권장 · 앉은 귀 높이 · 평소 예배 음량") {
            TextField("위치 이름 (예: 앞줄 중앙)", text: $positionName).textFieldStyle(.roundedBorder)
            HStack {
                Button {
                    let idx = model.isVerificationMode ? model.verificationPositions.count : model.currentSession.positions.count
                    let defaultName = model.isVerificationMode ? (model.currentSession.positions[safe: idx]?.name ?? "좌석 \(idx + 1)") : "좌석 \(idx + 1)"
                    let name = positionName.isEmpty ? defaultName : positionName
                    positionName = ""
                    Task { await model.measurePosition(named: name) }
                } label: {
                    Label(model.isMeasuring ? "측정 중…" : (model.isVerificationMode ? "검증: 이 위치 측정" : "이 위치 측정"), systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).disabled(model.isMeasuring)
                Button("새 세션") { model.newMeasurementSession() }.buttonStyle(.bordered)
            }
            if model.isMeasuring { HStack { ProgressView(); Text(model.measureStatus).font(.caption).foregroundStyle(.secondary) } }
            ForEach(model.currentSession.positions) { p in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.subheadline)
                        Text(String(format: "200–2k 평균 %.1f dB%@", p.response.meanDB(in: 200...2000), p.irPeakTimeMs.map { String(format: " · 지연 %.1f ms", $0) } ?? "")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { Task { await model.removePosition(p.id) } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
            if model.currentSession.positions.isEmpty && !model.isMeasuring {
                InfoNote(text: "아직 측정한 위치가 없습니다.")
            }
        }
    }

    func chartCard(_ avg: FrequencyResponse) -> some View {
        SectionCard(title: "응답 (1/6 옥타브 스무딩)") {
            let series = model.currentSession.positions.map { ($0.name, $0.response.smoothed(fractionOfOctave: 6)) } + [("공간 평균", avg.smoothed(fractionOfOctave: 6))]
            ResponseChart(series: series)
            if let dev = model.currentSession.deviation {
                KeyValueRow(key: "좌석 간 편차 (100 Hz–8 kHz)", value: String(format: "%.1f dB RMS", dev.meanDB(in: 100...8000)))
            }
        }
    }

    var savedCard: some View {
        SectionCard(title: "저장된 측정") {
            ForEach(model.sessions.prefix(8)) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                        Text("\(s.venueName) · \(s.positions.count)지점 · \(s.microphone.displayName)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("열기") { model.openSession(s) }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }
}

struct ChecklistSheet: View {
    @Environment(\.dismiss) var dismiss
    let items = [
        "UMIK-1 보정 파일을 앱에 등록 (시리얼 번호로 다운로드)",
        "측정용 빈 채널에 테스트 신호 연결, 채널 EQ·다이내믹스 끄기",
        "메인 출력 EQ를 평탄(0 dB)으로 초기화한 상태를 씬으로 저장",
        "평소 예배 음량에 가깝게 레벨 설정 (장시간 큰 음량 노출 주의)",
        "마이크를 앉은 귀 높이에 두고 좌석 5~8곳 측정",
        "보정 제안 확인 → 적용 → 같은 위치에서 재측정",
        "결과 씬을 새 번호로 저장"
    ]
    var body: some View {
        NavigationStack {
            List(items, id: \.self) { Label($0, systemImage: "checkmark.square") }
                .navigationTitle("공간 측정 체크리스트")
                .toolbar { Button("닫기") { dismiss() } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }
}
