import SwiftUI
import TuneMateCore

/// 상태 요약과 다음 할 일.
struct HomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page(title: "홈") {
            ErrorBanner()
            SectionCard(title: "지금 상태") {
                KeyValueRow(key: "믹서", value: model.settings.mixerModel.displayName)
                KeyValueRow(key: "연결", value: connectionText, valueColor: model.connectionStatus == .connected ? .green : .secondary)
                KeyValueRow(key: "운영 모드", value: model.settings.mode.displayName)
                KeyValueRow(key: "AI", value: aiText, valueColor: model.apiKey(model.settings.provider).isEmpty ? .orange : .primary)
                KeyValueRow(key: "마이크", value: micText)
                KeyValueRow(key: "최근 측정", value: measurementText)
                KeyValueRow(key: "지시함", value: model.peerLink.inbox.filter { $0.acknowledgedAt == nil }.isEmpty ? "처리할 지시 없음" : "미처리 \(model.peerLink.inbox.filter { $0.acknowledgedAt == nil }.count)건", valueColor: model.peerLink.inbox.contains { $0.acknowledgedAt == nil } ? .orange : .primary)
            }
            SectionCard(title: "다음 할 일", subtitle: "위에서부터 순서대로") {
                ForEach(todo, id: \.0) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.2 ? "checkmark.circle.fill" : "circle").foregroundStyle(item.2 ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.0).font(.subheadline).strikethrough(item.2)
                            if !item.2 { Text(item.1).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            SectionCard(title: "운영 규칙") {
                InfoNote(text: "예배 중에는 예배 잠금 모드만 씁니다. 측정과 자동 조정은 리허설 시간에만, 예배 시작 30분 전까지. 모든 변경은 스냅샷이 남은 상태에서만. 이상 동작 시 즉시 연결을 끊고 백업 씬을 불러옵니다.")
            }
            SectionCard(title: "정보") {
                InfoNote(text: "튠메이트 \(TuneMateInfo.version) — \(TuneMateInfo.disclaimer)")
            }
        }
    }

    var connectionText: String {
        if model.connectionStatus != .connected, let rc = model.remoteConsole { return "콘솔 기기 \(rc.deviceName) 경유" }
        switch model.connectionStatus {
        case .connected: return "연결됨" + (model.mixerState?.firmwareVersion.map { " · fw \($0)" } ?? "")
        case .connecting: return "연결 중…"
        case .disconnected: return "연결 안 됨"
        case .failed: return "실패"
        }
    }
    var aiText: String {
        let p = model.settings.provider
        return model.apiKey(p).isEmpty ? "\(p.displayName) 키 없음" : "\(p.displayName) · \(model.settings.chatTier.displayName)"
    }
    var micText: String {
        if model.settings.microphone == .simulated { return "시뮬레이션" }
        if let d = model.selectedInputDevice { return d.name }
        return model.settings.microphone.displayName
    }
    var measurementText: String {
        guard let s = model.sessions.first else { return "없음" }
        return "\(s.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(s.positions.count)지점"
    }
    var todo: [(String, String, Bool)] {
        [
            ("AI API 키 등록", "설정 → AI 공급자. 낮은 요금제면 경제형 등급.", !model.apiKey(model.settings.provider).isEmpty),
            ("측정마이크 연결·입력 레벨 확인", "측정 → 입력 장치에서 UMIK-1 선택 후 '입력 확인'.", model.selectedInputDevice?.looksLikeUMIK == true || model.settings.microphone == .simulated),
            ("믹서 연결 테스트", "믹서 → IP 입력 → 연결 테스트 → 연결. 또는 지시함에서 기기 연결을 켜 콘솔 기기를 경유.", model.connectionStatus == .connected || model.remoteConsole != nil),
            ("좌석 5~8곳 측정", "측정 탭. 앉은 귀 높이, 평소 예배 음량.", (model.sessions.first?.positions.count ?? 0) >= 5),
            ("보정값 확인·적용·재측정", "보정 탭. 미연결이면 표를 복사해 공식 앱에 입력.", model.sessions.first?.appliedToMixer == true)
        ]
    }
}
