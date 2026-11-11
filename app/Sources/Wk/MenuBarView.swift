import SwiftUI
import WkKit

/// The menu-bar dropdown: live status, pinned/active/recent tasks, and entry points.
struct MenuBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("\(store.snapshot.counts.running)", systemImage: "play.circle.fill").foregroundStyle(Theme.running).help("Claude working")
                Label("\(store.snapshot.counts.waiting)", systemImage: "bell.circle.fill").foregroundStyle(Theme.waiting).help("Waiting for you")
                Label("\(store.snapshot.counts.open)", systemImage: "circle.inset.filled").foregroundStyle(Theme.open).help("Open in cmux")
                Spacer()
                if !store.snapshot.cmuxRunning { Chip(text: "cmux off", color: .orange) }
            }
            .font(.system(size: 12, weight: .semibold))
            Divider()
            if store.coreMissing {
                Text("wk core not found — run make install").foregroundStyle(.red).font(.caption)
            }
            ForEach(store.pinnedAndRecent) { task in
                Button {
                    dismiss()
                    store.open(task)
                } label: {
                    TaskRow(task: task, selected: false)
                }
                .buttonStyle(.plain)
            }
            if let activity = store.activities.first, !activity.done {
                Divider()
                HStack {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading) {
                        Text(activity.title).font(.caption.bold())
                        Text(activity.lines.last ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Divider()
            HStack {
                Button("Open Wk") { show() }.keyboardShortcut("o")
                Button("New task…") { show(.newTask(NewTaskSeed())) }
                Button("Cleanup…") { show(tab: .cleanup) }
                Spacer()
                Button { show(tab: .settings) } label: { Image(systemName: "gearshape") }.help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit Wk")
            }
            .buttonStyle(.borderless)
            Text("\(HotKey.combo(for: UserDefaults.standard.string(forKey: "hotkey")).label) opens Wk from anywhere")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 440)
        .onAppear { store.refresh(.all) }
    }

    private func show(_ overlay: Overlay? = nil, tab: PaletteTab? = nil) {
        dismiss()
        PaletteController.shared.show(overlay: overlay, tab: tab)
    }
}
