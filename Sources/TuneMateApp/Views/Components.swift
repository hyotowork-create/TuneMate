import SwiftUI
import TuneMateCore

/// 제목 + 내용 카드. iOS GroupBox 의 큰 제목 대신 일관된 스타일.
struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension Color {
    static var cardBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }
    static var pageBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }
}

/// 넓으면 가로, 좁으면 세로.
struct AdaptiveStack<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder let content: Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: spacing) { content }
            VStack(alignment: .leading, spacing: spacing) { content }
        }
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var valueColor: Color = .primary
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(valueColor).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}

struct ModeBadge: View {
    let mode: OperatingMode
    var body: some View {
        StatusPill(text: mode.displayName, color: mode == .serviceLock ? .red : mode == .rehearsalAuto ? .orange : .blue)
    }
}

struct InfoNote: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text).font(.caption).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
    }
}

struct ErrorBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let e = model.lastError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(e).font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { model.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(10).background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct LevelBar: View {
    let db: Double?
    var floor: Double = -60
    var body: some View {
        GeometryReader { g in
            let v = max(0, min(1, ((db ?? -120) - floor) / -floor))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 3).fill(v > 0.9 ? Color.red : v > 0.75 ? Color.orange : Color.green).frame(width: g.size.width * v)
            }
        }
        .frame(height: 10)
    }
}

/// 페이지 공통 스크롤 컨테이너
struct Page<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
        }
        .background(Color.pageBackground)
        .navigationTitle(title)
    }
}

struct OutcomeText: View {
    let text: String
    var body: some View {
        if !text.isEmpty {
            Text(text).font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

extension View {
    /// 변경 결과를 한 줄 문장으로
    func outcomeDescription(_ out: ExecutionOutcome) -> String {
        switch out {
        case .applied(let e): return "적용됨: " + e.summaries.joined(separator: "; ")
        case .denied(let r): return "적용 불가: " + r.joined(separator: " ")
        case .awaitingApproval(_, let r): return "승인 필요: " + r.joined(separator: " ")
        }
    }
}
