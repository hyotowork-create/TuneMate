import SwiftUI
import TuneMateCore

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    @State private var input = ""

    var hasKey: Bool { !model.apiKey(model.settings.provider).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ErrorBanner().padding(.horizontal, 12).padding(.top, 6)
            if !hasKey {
                InfoNote(text: "\(model.settings.provider.displayName) API 키가 없습니다. 설정에서 등록하세요. 낮은 요금제면 '경제형' 등급을 권장합니다.", tint: .orange)
                    .padding(.horizontal, 16).padding(.top, 8)
            }
            messages
            Divider()
            inputBar
        }
        .background(Color.pageBackground)
        .navigationTitle("AI 대화")
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    Picker("AI", selection: $model.settings.provider) { ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) } }
                } label: { Label(model.settings.provider.displayName, systemImage: "cpu").lineLimit(1) }
                Menu {
                    Picker("등급", selection: $model.settings.chatTier) { ForEach(ModelTier.allCases) { Text("\($0.displayName) — \($0.explanation)").tag($0) } }
                } label: { Label(model.settings.chatTier.displayName, systemImage: "gauge.with.dots.needle.33percent").lineLimit(1) }
                Spacer()
                Button("새 대화") { Task { await model.resetChat() } }.font(.caption)
            }
            .menuStyle(.button).buttonStyle(.bordered).controlSize(.small)
            HStack(spacing: 8) {
                Text(model.settings.catalog.model(model.settings.provider, model.settings.chatTier)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                ModeBadge(mode: model.settings.mode)
                Text("토큰 \(model.usage.inputTokens)/\(model.usage.outputTokens)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .onChange(of: model.settings.provider) { _, _ in model.saveSettings() }
        .onChange(of: model.settings.chatTier) { _, _ in model.saveSettings() }
    }

    var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.chatTurns.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("이렇게 말해 보세요").font(.caption).foregroundStyle(.secondary)
                            ForEach(["1번 마이크 목소리가 안 들려요", "1·5·6번 보컬 모니터(AUX1) 2 dB 올려줘", "측정 결과를 분석해 줘", "지금 상태 요약해 줘"], id: \.self) { ex in
                                Button(ex) { input = ex }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        .padding(.top, 8)
                    }
                    ForEach(model.chatTurns) { t in TurnRow(turn: t).id(t.id) }
                    if model.isThinking { HStack { ProgressView(); Text("생각 중…").font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 6) }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(maxWidth: 820).frame(maxWidth: .infinity)
            }
            .onChange(of: model.chatTurns.count) { _, _ in if let last = model.chatTurns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
        }
    }

    var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("예: 설교 마이크가 작아요", text: $input, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder).onSubmit(send)
            Button { send() } label: { Image(systemName: "paperplane.fill") }.buttonStyle(.borderedProminent).disabled(model.isThinking || input.isEmpty || !hasKey)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    func send() { let t = input; input = ""; Task { await model.sendChat(t) } }
}

struct TurnRow: View {
    let turn: AssistantTurn
    @State private var expanded = false
    var body: some View {
        switch turn.role {
        case .user:
            HStack { Spacer(minLength: 40); Text(turn.text).padding(10).background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12)) }
        case .assistant:
            HStack { Text(turn.text).padding(10).background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12)).textSelection(.enabled); Spacer(minLength: 40) }
        case .tool:
            DisclosureGroup(isExpanded: $expanded) {
                Text(turn.detail ?? "").font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } label: { Label("도구 \(turn.text)", systemImage: "wrench.and.screwdriver").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct ApprovalSheet: View {
    @EnvironmentObject var model: AppModel
    let pending: AppModel.PendingApproval
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("변경 승인").font(.title2).bold()
            if !pending.proposal.rationale.isEmpty { Text(pending.proposal.rationale).font(.callout) }
            ForEach(pending.proposal.resolved) { r in
                HStack(alignment: .top, spacing: 6) { Image(systemName: "arrow.right").foregroundStyle(.secondary); Text(r.summary).font(.subheadline) }
            }
            if pending.proposal.resolved.isEmpty && !pending.proposal.changes.isEmpty { Text("\(pending.proposal.changes.count)건").font(.caption) }
            Divider()
            ForEach(pending.reasons, id: \.self) { InfoNote(text: "• " + $0, tint: .orange) }
            InfoNote(text: "적용 직전에 스냅샷이 저장되며 믹서 탭에서 한 번에 되돌릴 수 있습니다.")
            HStack {
                Button("지시로 보내기") { _ = model.sendInstruction(pending.proposal); model.resolveApproval(false) }.buttonStyle(.bordered)
                Spacer()
                Button("거절") { model.resolveApproval(false) }.keyboardShortcut(.cancelAction)
                Button("승인하고 적용") { model.resolveApproval(true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(minWidth: 460)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
}
