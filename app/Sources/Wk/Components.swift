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
            if !task.hasFolder && !task.detached { Chip(text: "no folder") }
            Text(RelativeTime.short(task.lastActivity))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
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
            Text("\(session.prompts)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary).help("prompts")
            Text(RelativeTime.short(session.last))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
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
            }
        }
        .transition(.opacity)
    }
}
