import SwiftUI
import TuneMateCore

/// 지시함: 다른 기기에서 받은 수정 지시를 체크리스트로 보여 주고, 읽어 주고, 완료를 돌려보낸다.
struct InstructionsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var link: PeerLink

    init(link: PeerLink) { self.link = link }

    var body: some View {
        Page(title: "지시함") {
            SectionCard(title: "같은 아이패드의 공식 앱과 쓰기", subtitle: "공식 믹서 앱 위에 체크리스트를 작은 창으로 띄웁니다") {
                #if os(iOS)
                if model.overlay.isSupported {
                    AdaptiveStack {
                        Button(model.overlay.isActive ? "작은 창 닫기" : "작은 창으로 띄우기 (PiP)") {
                            if model.overlay.isActive { model.overlay.hide() }
                            else if let first = link.inbox.first(where: { $0.acknowledgedAt == nil }) ?? link.inbox.first { model.overlay.show(first) }
                        }
                        .buttonStyle(.borderedProminent).disabled(link.inbox.isEmpty)
                        Button("체크리스트 미리보기") { if let first = link.inbox.first { model.overlay.update(first) } }.buttonStyle(.bordered).disabled(link.inbox.isEmpty)
                    }
                    InfoNote(text: "띄운 뒤 홈으로 나가 공식 DM24.8 앱을 열면 작은 창이 그 위에 남습니다. 항목을 체크하려면 창을 눌러 튠메이트로 돌아오거나 Split View 로 두 앱을 나란히 두세요. 새 지시가 오면 알림 배너로도 뜹니다.")
                    if !model.overlay.lastError.isEmpty { InfoNote(text: model.overlay.lastError, tint: .orange) }
                } else {
                    InfoNote(text: "이 기기는 PiP 를 지원하지 않습니다. Split View 로 공식 앱과 나란히 두세요.")
                }
                #else
                InfoNote(text: "Mac 에서는 튠메이트 창을 공식 앱 옆에 두면 됩니다. 받은 지시는 알림으로도 표시됩니다.")
                #endif
            }
            SectionCard(title: "기기 연결", subtitle: "같은 Wi-Fi 또는 블루투스 범위의 튠메이트 기기끼리 자동 연결") {
                HStack {
                    Button(link.isActive ? "연결 끄기" : "연결 켜기") { link.isActive ? link.stop() : link.start() }.buttonStyle(.borderedProminent)
                    Spacer()
                    Text("이 기기: \(link.deviceName)").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("앱 시작 시 자동으로 켜기", isOn: $model.settings.autoStartPeerLink).onChange(of: model.settings.autoStartPeerLink) { _, _ in model.saveSettings() }
                if link.peers.isEmpty { InfoNote(text: link.isActive ? "연결된 기기 없음 — 다른 기기에서도 지시함의 '연결 켜기'를 누르세요." : "꺼짐") }
                ForEach(link.peers, id: \.displayName) { p in
                    HStack {
                        Label(p.displayName, systemImage: "ipad.and.iphone").font(.subheadline)
                        Spacer()
                        if let c = link.consoles[p.displayName] {
                            StatusPill(text: c.connected ? "믹서 연결됨 · \(c.mode.displayName)" : "믹서 미연결", color: c.connected ? .green : .secondary)
                        }
                    }
                }
                InfoNote(text: "연결되면 믹서 상태·운영 모드·측정 결과·채널 이름표가 기기 간에 자동으로 공유되고, 믹서에 연결된 기기가 다른 기기의 변경안을 받아 적용합니다.")
                if !link.lastEvent.isEmpty { InfoNote(text: link.lastEvent) }
                InfoNote(text: "콘솔 아이패드에서는 공식 DM24.8 앱과 튠메이트를 Split View 로 나란히 띄우고, 카드의 항목을 보며 입력한 뒤 '완료'를 누르면 측정 기기에 알려집니다.")
            }
            SectionCard(title: "받은 지시 (\(link.inbox.count))") {
                if link.inbox.isEmpty { InfoNote(text: "받은 지시 없음") }
                ForEach(link.inbox) { ins in InstructionCard(instruction: ins, link: link) }
            }
            if !link.sent.isEmpty {
                SectionCard(title: "보낸 지시") {
                    ForEach(link.sent) { ins in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ins.title).font(.subheadline)
                                Text("\(ins.createdAt.formatted(date: .omitted, time: .shortened)) · \(ins.steps.count)항목").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusPill(text: ins.acknowledgedAt == nil ? "대기" : "완료 확인", color: ins.acknowledgedAt == nil ? .orange : .green)
                        }
                    }
                }
            }
        }
    }
}

struct InstructionCard: View {
    let instruction: Instruction
    @ObservedObject var link: PeerLink
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(instruction.title).font(.headline)
                    Text("\(instruction.from) · \(instruction.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if instruction.acknowledgedAt != nil { StatusPill(text: "완료", color: .green) }
            }
            if !instruction.rationale.isEmpty { Text(instruction.rationale).font(.caption) }
            ForEach(instruction.steps) { st in
                Button { link.toggleStep(instruction.id, st.id) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: st.done ? "checkmark.circle.fill" : "circle").foregroundStyle(st.done ? .green : .secondary)
                        Text(st.text).font(.subheadline.monospacedDigit()).strikethrough(st.done).multilineTextAlignment(.leading)
                    }
                }.buttonStyle(.plain)
            }
            AdaptiveStack {
                Button { link.speak(instruction) } label: { Label("읽어주기", systemImage: "speaker.wave.2") }
                Button("완료 알리기") { link.acknowledge(instruction.id) }.disabled(instruction.acknowledgedAt != nil)
                Button(role: .destructive) { link.remove(instruction.id) } label: { Text("삭제") }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(10).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
