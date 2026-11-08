import SwiftUI
import TuneMateCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            AISettingsSection()
            VenueSettingsSection()
            SafetySettingsSection()
            MeasureSettingsSection()
            Section("DM24.8 프로토콜") {
                Text("명세 파일 dm248-protocol.yaml (status: unverified). Phase 0 캡처로 값을 채우고 verified 로 바꾸면 자동 적용이 열립니다. 그 전에는 읽기·제안만 합니다.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("설정")
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
    }
}

struct AISettingsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var keys: [AIProviderKind: String] = [:]

    var body: some View {
        Section("AI 공급자와 API 키 (본인 키, Keychain 에 저장)") {
            Picker("기본 공급자", selection: $model.settings.provider) { ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) } }
            ForEach(AIProviderKind.allCases) { p in
                KeyRow(provider: p, text: Binding(get: { keys[p] ?? "" }, set: { keys[p] = $0 }))
            }
            Picker("대화·조정 등급", selection: $model.settings.chatTier) { ForEach(ModelTier.allCases) { Text("\($0.displayName) — \($0.explanation)").tag($0) } }
            Picker("측정 분석 등급", selection: $model.settings.analysisTier) { ForEach(ModelTier.allCases) { Text($0.displayName).tag($0) } }
            DisclosureGroup("모델 ID (공급자 콘솔에서 확인해 바꿀 수 있음)") {
                ForEach(AIProviderKind.allCases) { p in
                    ForEach(ModelTier.allCases) { t in
                        TextField("\(p.displayName) \(t.displayName)", text: Binding(get: { model.settings.catalog.model(p, t) }, set: { model.settings.catalog.set(p, t, $0) }))
                    }
                }
            }
        }
    }
}

struct KeyRow: View {
    @EnvironmentObject var model: AppModel
    let provider: AIProviderKind
    @Binding var text: String
    var body: some View {
        HStack {
            SecureField(provider.keyHint, text: $text)
            Button(model.apiKey(provider).isEmpty ? "저장" : "교체") { model.setAPIKey(provider, text); text = "" }
            if !model.apiKey(provider).isEmpty { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        }
    }
}

struct VenueSettingsSection: View {
    @EnvironmentObject var model: AppModel
    var labelsText: Binding<String> {
        Binding(
            get: { model.settings.venue.channelLabels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") },
            set: { s in
                var d: [Int: String] = [:]
                for part in s.split(separator: ",") {
                    let kv = part.split(separator: "=", maxSplits: 1)
                    if kv.count == 2, let k = Int(kv[0].trimmingCharacters(in: .whitespaces)) { d[k] = kv[1].trimmingCharacters(in: .whitespaces) }
                }
                model.settings.venue.channelLabels = d
            })
    }
    var body: some View {
        Section("공간·채널 이름표 (AI 에 매 요청 함께 보냄)") {
            TextField("예배당 이름", text: $model.settings.venue.name)
            Stepper("좌석 수 \(model.settings.venue.seats)", value: $model.settings.venue.seats, in: 10...5000, step: 10)
            TextField("스피커 구성", text: $model.settings.venue.speakerLayout)
            TextField("채널 이름표 (예: 1=설교, 5=찬양 보컬 1)", text: labelsText)
        }
    }
}

struct SafetySettingsSection: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Section("안전 한도") {
            Stepper("한 번에 올릴 수 있는 폭 +\(Int(model.settings.policy.maxIncreaseStepDB)) dB", value: $model.settings.policy.maxIncreaseStepDB, in: 1...10, step: 1)
            Stepper("메인 출력 상한 \(Int(model.settings.policy.mainOutputCapDB)) dB", value: $model.settings.policy.mainOutputCapDB, in: -20...10, step: 1)
            Stepper("한 번에 뮤트 가능 채널 \(model.settings.policy.maxMutesPerProposal)개", value: $model.settings.policy.maxMutesPerProposal, in: 0...24)
            Stepper("노치 한 번 \(Int(model.settings.policy.notch.stepDB)) dB", value: $model.settings.policy.notch.stepDB, in: -6 ... -1, step: 1)
            Stepper("노치 최대 \(Int(model.settings.policy.notch.maxDepthDB)) dB", value: $model.settings.policy.notch.maxDepthDB, in: -24 ... -3, step: 1)
            Toggle("미검증 프로토콜 믹서에는 쓰기 차단", isOn: $model.settings.policy.blockWritesToUnverifiedProtocol)
        }
    }
}

struct MeasureSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var calText = ""
    @State private var calStatus = ""
    var body: some View {
        Section("측정") {
            Picker("마이크", selection: $model.settings.microphone) { ForEach(MicrophoneKind.allCases) { Text($0.displayName).tag($0) } }
            Stepper("스윕 길이 \(Int(model.settings.sweep.durationSeconds))초", value: $model.settings.sweep.durationSeconds, in: 3...20, step: 1)
            Stepper("부스트 한도 +\(Int(model.settings.autoEQ.maxBoostDB)) dB", value: $model.settings.autoEQ.maxBoostDB, in: 0...6, step: 1)
            Stepper("필터 수 \(model.settings.autoEQ.maxFilters) (메인 출력 EQ 밴드 수)", value: $model.settings.autoEQ.maxFilters, in: 1...31)
            Stepper("딥 제외 기준 \(Int(model.settings.autoEQ.dipExclusionDB)) dB", value: $model.settings.autoEQ.dipExclusionDB, in: -20 ... -3, step: 1)
            VStack(alignment: .leading) {
                Text("UMIK-1 보정 파일 (텍스트 붙여넣기)").font(.caption)
                TextEditor(text: $calText).frame(minHeight: 80).font(.caption.monospaced())
                HStack {
                    Button("등록") { register() }
                    Text(calStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { calText = model.settings.calibrationText ?? "" }
    }

    func register() {
        do {
            let c = try MicrophoneCalibration.parse(calText)
            model.calibration = c
            model.settings.calibrationText = calText
            calStatus = "등록됨: \(c.frequencies.count)점, 시리얼 \(c.serialNumber ?? "-")"
        } catch { calStatus = "해석 실패: \(error)" }
    }
}
