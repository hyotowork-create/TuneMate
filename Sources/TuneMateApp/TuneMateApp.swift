import SwiftUI
import TuneMateCore

@main
struct TuneMateApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("튠메이트") {
            RootView()
                .environmentObject(model)
                .environment(\.locale, Locale(identifier: "ko_KR"))
                .task { await model.load() }
                .sheet(item: $model.pendingApproval, onDismiss: { model.approvalSheetDismissed() }) { p in ApprovalSheet(pending: p).environmentObject(model) }
        }
        #if os(macOS)
        .defaultSize(width: 1120, height: 760)
        #endif
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case home, measure, analysis, feedback, chat, mixer, instructions, settings
    var id: String { rawValue }
    var title: String {
        switch self { case .home: return "홈"; case .measure: return "측정"; case .analysis: return "보정"; case .feedback: return "하울링"; case .chat: return "AI 대화"; case .mixer: return "믹서"; case .instructions: return "지시함"; case .settings: return "설정" }
    }
    var icon: String {
        switch self { case .home: return "house"; case .measure: return "waveform.badge.mic"; case .analysis: return "slider.horizontal.3"; case .feedback: return "exclamationmark.triangle"; case .chat: return "bubble.left.and.text.bubble.right"; case .mixer: return "dial.medium"; case .instructions: return "tray.full"; case .settings: return "gearshape" }
    }
    // iPhone: 탭 4개 + 더보기 (시스템 More 가 생기지 않도록 5개 이하)
    static let primaryTabs: [AppSection] = [.home, .measure, .analysis, .chat]
    static let moreTabs: [AppSection] = [.feedback, .mixer, .instructions, .settings]
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: AppSection? = .home

    var body: some View {
        if sizeClass == .compact {
            TabView {
                ForEach(AppSection.primaryTabs) { s in
                    NavigationStack { SectionContent(section: s) }.tabItem { Label(s.title, systemImage: s.icon) }
                }
                NavigationStack {
                    List {
                        ForEach(AppSection.moreTabs) { s in
                            NavigationLink { SectionContent(section: s) } label: { Label(s.title, systemImage: s.icon) }
                        }
                    }
                    .navigationTitle("더보기")
                }
                .tabItem { Label("더보기", systemImage: "ellipsis.circle") }
            }
        } else {
            NavigationSplitView {
                List(selection: $selection) {
                    Section("작업") { ForEach([AppSection.home, .measure, .analysis, .feedback, .chat]) { s in Label(s.title, systemImage: s.icon).tag(s) } }
                    Section("장비") { ForEach([AppSection.mixer, .instructions, .settings]) { s in Label(s.title, systemImage: s.icon).tag(s) } }
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
                .safeAreaInset(edge: .bottom) { StatusFooter().padding(10) }
            } detail: {
                NavigationStack { SectionContent(section: selection ?? .home) }
            }
        }
    }
}

struct SectionContent: View {
    @EnvironmentObject var model: AppModel
    let section: AppSection
    var body: some View {
        switch section {
        case .home: HomeView()
        case .measure: MeasureView()
        case .analysis: AnalysisView()
        case .feedback: FeedbackView()
        case .chat: ChatView()
        case .mixer: MixerView()
        case .instructions: InstructionsView(link: model.peerLink)
        case .settings: SettingsView()
        }
    }
}

struct StatusFooter: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(model.connectionStatus == .connected ? .green : .gray).frame(width: 8, height: 8)
                Text(model.settings.mixerModel.displayName).font(.caption).lineLimit(1)
            }
            ModeBadge(mode: model.settings.mode)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
