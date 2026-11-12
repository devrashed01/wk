import SwiftUI
import WkKit

enum Theme {
    static let running = Color.cyan
    static let waiting = Color.orange
    static let open = Color.green
    static let danger = Color.red
    static let muted = Color.secondary
}

/// ▶ running · ● waiting for you · ◉ open in cmux · nothing when idle.
struct TaskStatusIcon: View {
    let task: WkTask

    var body: some View {
        Group {
            if task.running > 0 {
                Image(systemName: "play.circle.fill").foregroundStyle(Theme.running).help("Claude is working")
            } else if task.waiting > 0 {
                Image(systemName: "bell.circle.fill").foregroundStyle(Theme.waiting).help("Claude is waiting for you")
            } else if task.isOpen {
                Image(systemName: "circle.inset.filled").foregroundStyle(Theme.open).help("Open in cmux")
            } else {
                Image(systemName: "circle").foregroundStyle(.quaternary)
            }
        }
        .font(.system(size: 13))
        .frame(width: 16)
    }
}

struct SessionStateIcon: View {
    let session: Session

    var body: some View {
        switch session.state {
        case .running: Image(systemName: "play.circle.fill").foregroundStyle(Theme.running).help("Running")
        case .waiting: Image(systemName: "bell.circle.fill").foregroundStyle(Theme.waiting).help("Waiting for you")
        case .idle: Image(systemName: "bubble.left").foregroundStyle(.secondary).help("Idle")
        case .orphan: Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow).help("Folder or branch is gone")
        }
    }
}

struct Chip: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }
}

struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

struct TaskRow: View {
    let task: WkTask
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            TaskStatusIcon(task: task)
            Text(task.repoLabel)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if task.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                    if task.isLinkedWorktree {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.teal).help("Worktree — its own folder, separate from the main checkout")
                    }
                    Text(task.branch).font(.system(size: 13, weight: .medium)).lineLimit(1)
                }
                Text(task.latestSession?.displayTitle ?? task.subject ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if task.dirty > 0 { Chip(text: "\(task.dirty)", color: .orange, systemImage: "pencil") }
            if task.ahead > 0 { Chip(text: "↑\(task.ahead)", color: .blue) }
            if !task.hasFolder && !task.detached { Chip(text: "not checked out", systemImage: "folder.badge.questionmark")
                    .help("This branch has no folder on disk. Opening it asks where to check it out.") }
            TimeLabel(date: task.lastActivity)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

struct SessionRow: View {
    let session: Session
    let selected: Bool
    var showRepo = true

    var body: some View {
        HStack(spacing: 8) {
            SessionStateIcon(session: session).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    if showRepo, let repo = session.repo { Text(URL(fileURLWithPath: repo).lastPathComponent.uppercased()).bold() }
                    Text(session.branch.isEmpty ? PathDisplay.collapse(session.cwd) : session.branch)
                    if session.trashed == true { Text("in trash").foregroundStyle(.red) }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                TimeLabel(date: session.last)
                if let size = session.sizeLabel {
                    Text(size + (session.resumeCostCompact.map { " \($0)" } ?? ""))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                        .help("transcript size — resuming re-reads roughly this many tokens")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

/// Relative time with a clock glyph, so "22m" can't be misread as a quantity.
struct TimeLabel: View {
    let date: Date

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock").font(.system(size: 9))
            Text(RelativeTime.short(date)).font(.system(size: 11).monospacedDigit())
        }
        .foregroundStyle(.secondary)
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

/// A quiet card that groups one topic in a detail panel.
struct DetailCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.07)))
    }
}

/// One aligned label/value line inside a DetailCard.
struct FactRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            value.frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// A modal step shown in place of the palette content: same full-screen backdrop, no card.
/// The main layout fades out behind it (see PaletteLayout); clicking empty space or esc closes it.
struct OverlayCard<Content: View>: View {
    let title: String
    var width: CGFloat = 520
    @ViewBuilder var content: Content
    @Environment(AppStore.self) private var store

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { store.overlay = nil }
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.system(size: 24, weight: .semibold)).lineLimit(2)
                        Spacer()
                        Button { store.overlay = nil } label: { KeyHint(keys: "esc", label: "Back") }
                            .buttonStyle(.plain)
                    }
                    content
                }
                .frame(width: min(max(width, 640), geometry.size.width - 48))
                .padding(.top, geometry.size.height * 0.09)
                .padding(.bottom, 56)
                .frame(maxHeight: geometry.size.height, alignment: .top)
            }
        }
        .transition(.opacity)
    }
}

/// A select field with search: shows the current choice, and opens in place into a filter box
/// over a short scrolling list. Type to narrow, ↑↓ to move, ↵ to choose, esc to close.
struct SearchableSelect: View {
    struct Option: Identifiable, Equatable {
        let value: String
        let label: String
        var id: String { value }
    }

    let options: [Option]
    @Binding var selection: String
    var placeholder = "Choose…"
    var searchPrompt = "Search…"

    @State private var open = false
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var searching: Bool

    private var matches: [Option] {
        let terms = query.lowercased().split(separator: " ")
        guard !terms.isEmpty else { return options }
        return options.filter { option in terms.allSatisfy { option.label.lowercased().contains($0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if open { searchField; list } else { closedField }
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onChange(of: options) { _, _ in highlighted = 0 }
    }

    private var closedField: some View {
        Button { show() } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.value == selection }?.label ?? placeholder)
                    .foregroundStyle(selection.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(options.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to search \(options.count) choices")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("", text: $query, prompt: Text(searchPrompt))
                .labelsHidden()
                .textFieldStyle(.plain)
                .focused($searching)
                .onSubmit { choose(matches.indices.contains(highlighted) ? matches[highlighted] : nil) }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
            Text("\(matches.count) of \(options.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5))
    }

    private var list: some View {
        let shown = Array(matches.prefix(200))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if shown.isEmpty {
                        Text("No match").font(.system(size: 12)).foregroundStyle(.secondary).padding(6)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, option in
                        HStack(spacing: 6) {
                            Text(option.label).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            if option.value == selection { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index == highlighted ? Color.accentColor.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                        .onTapGesture { choose(option) }
                        .id(index)
                    }
                    if matches.count > shown.count {
                        Text("\(matches.count - shown.count) more — keep typing to narrow").font(.system(size: 11)).foregroundStyle(.tertiary).padding(6)
                    }
                }
                .padding(3)
            }
            .frame(height: min(220, CGFloat(max(shown.count, 1)) * 27 + (matches.count > shown.count ? 30 : 8)))
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08)))
            .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
        }
    }

    private func show() {
        query = ""
        highlighted = max(0, options.firstIndex { $0.value == selection } ?? 0)
        open = true
        Task {
            searching = true
            try? await Task.sleep(for: .milliseconds(60))
            searching = true
        }
    }

    private func close() {
        open = false
        searching = false
    }

    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        highlighted = min(max(highlighted + delta, 0), min(matches.count, 200) - 1)
    }

    private func choose(_ option: Option?) {
        if let option { selection = option.value }
        close()
    }
}
