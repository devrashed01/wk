import SwiftUI
import WkKit

/// The hotkey window: the whole screen is the app. A blurred, dimmed backdrop; search at the top
/// center, tab pills under it, list + detail below, key hints at the bottom. No card, no border.
struct PaletteView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ZStack {
            Backdrop(blur: store.blurBackdrop, opacity: store.backdropOpacity)
                .contentShape(Rectangle())
                .onTapGesture { PaletteController.shared.hide() }
            PaletteLayout()
        }
        .ignoresSafeArea()
    }
}

/// Desktop blur (behind the window) plus a dark tint whose strength the user picks in Settings.
struct Backdrop: View {
    let blur: Bool
    let opacity: Double

    var body: some View {
        ZStack {
            if blur { VisualEffect(material: .fullScreenUI) }
            Color.black.opacity(opacity)
        }
        .animation(.easeOut(duration: 0.15), value: opacity)
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

struct PaletteLayout: View {
    @Environment(AppStore.self) private var store
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var store = store
        ZStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    VStack(spacing: 14) {
                        searchField
                        tabPills
                    }
                    .padding(.top, geometry.size.height * 0.09)
                    content
                        .frame(maxWidth: min(1320, geometry.size.width * 0.92), maxHeight: .infinity)
                        .padding(.top, geometry.size.height * 0.04)
                    hintBar
                        .padding(.vertical, 18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .opacity(store.overlay == nil ? 1 : 0)
            .allowsHitTesting(store.overlay == nil)
            if store.overlay == nil { closeHint }

            if let overlay = store.overlay {
                OverlayHost(overlay: overlay)
            }
            if let toast = store.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.thickMaterial, in: Capsule())
                        .shadow(radius: 6)
                        .padding(.bottom, 64)
                        .onTapGesture { store.toast = nil }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.overlay)
        .background(shortcuts)
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .wkFocusSearch)) { _ in
            searchFocused = false
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: store.overlay) { _, overlay in searchFocused = overlay == nil }
        .onChange(of: store.query) { _, _ in queryChanged() }
        .onChange(of: store.tab) { _, tab in tabChanged(tab) }
    }

    private var searchField: some View {
        @Bindable var store = store
        return HStack(spacing: 14) {
            Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(.secondary)
            TextField(placeholder, text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 24))
                .focused($searchFocused)
                // While an overlay is open it owns the keyboard; never drive the list behind it.
                .onKeyPress(.upArrow) { guard store.overlay == nil else { return .ignored }; move(-1); return .handled }
                .onKeyPress(.downArrow) { guard store.overlay == nil else { return .ignored }; move(1); return .handled }
                .onKeyPress(keys: [.return]) { press in
                    guard store.overlay == nil else { return .ignored }
                    primaryAction(single: press.modifiers.contains(.command)); return .handled
                }
            if !store.snapshot.cmuxRunning && store.snapshot.generatedAt > .distantPast {
                Chip(text: "cmux not running", color: .orange, systemImage: "exclamationmark.triangle")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.10)))
        .frame(width: 760)
    }

    private var tabPills: some View {
        HStack(spacing: 4) {
            ForEach(PaletteTab.allCases) { tab in
                Button { store.tab = tab } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: store.tab == tab ? .medium : .regular))
                        .foregroundStyle(store.tab == tab ? .primary : .secondary)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(store.tab == tab ? Color.white.opacity(0.09) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var closeHint: some View {
        VStack {
            HStack {
                Spacer()
                Button { PaletteController.shared.hide() } label: { KeyHint(keys: "esc", label: "Close") }
                    .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 18).padding(.trailing, 24)
    }

    private var placeholder: String {
        switch store.tab {
        case .tasks: "Search tasks — ticket, branch, repo, session title…"
        case .sessions: "Search every Claude session…"
        case .cleanup: "Filter cleanup suggestions…"
        case .settings: "Settings"
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.coreMissing {
            EmptyState(symbol: "wrench.and.screwdriver", title: "wk core not found",
                       subtitle: "Reinstall Wk.app, or put the wk binary in ~/go/bin or /opt/homebrew/bin.")
        } else {
            switch store.tab {
            case .tasks: TasksPane()
            case .sessions: SessionsPane()
            case .cleanup: CleanupPane()
            case .settings: SettingsPane()
            }
        }
    }

    private var hintBar: some View {
        HStack(spacing: 20) {
            switch store.tab {
            case .tasks:
                KeyHint(keys: "↵", label: "Open")
                KeyHint(keys: "⌘↵", label: "Single pane")
                KeyHint(keys: "⌘K", label: "All actions")
                KeyHint(keys: "⌘N", label: "New task")
                KeyHint(keys: "⌘R", label: "Pick session")
                KeyHint(keys: "⌘⌫", label: "Remove")
                KeyHint(keys: "⌘P", label: "Pin")
            case .sessions:
                KeyHint(keys: "↵", label: "Resume")
                KeyHint(keys: "⌘↵", label: "Single pane")
                KeyHint(keys: "⌘K", label: "All actions")
                KeyHint(keys: "⌘⌫", label: "Trash")
            case .cleanup:
                KeyHint(keys: "↑↓", label: "Move")
                KeyHint(keys: "↵", label: "Select")
                KeyHint(keys: "⌘↵", label: "Remove selected")
            case .settings:
                EmptyView()
            }
            KeyHint(keys: "⌘1–4 ⌘←→", label: "Tabs")
            // Activities that run while the palette stays open (cleanup, settings) show here.
            if let activity = store.activities.first, !activity.done {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(activity.lines.last ?? activity.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: 320)
            }
        }
    }

    /// Invisible buttons that own the ⌘ shortcuts while the palette is key.
    private var shortcuts: some View {
        Group {
            Button("") { store.tab = .tasks }.keyboardShortcut("1", modifiers: .command)
            Button("") { store.tab = .sessions }.keyboardShortcut("2", modifiers: .command)
            Button("") { store.tab = .cleanup }.keyboardShortcut("3", modifiers: .command)
            Button("") { store.tab = .settings }.keyboardShortcut("4", modifiers: .command)
            Button("") { cycleTab(-1) }.keyboardShortcut(.leftArrow, modifiers: .command)
            Button("") { cycleTab(1) }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("") { openActions() }.keyboardShortcut("k", modifiers: .command)
            Button("") { newTask() }.keyboardShortcut("n", modifiers: .command)
            Button("") { removeSelected() }.keyboardShortcut(.delete, modifiers: .command)
            Button("") { pickSession() }.keyboardShortcut("r", modifiers: .command)
            Button("") { togglePin() }.keyboardShortcut("p", modifiers: .command)
            Button("") { store.refresh(.all) }.keyboardShortcut("r", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .disabled(store.overlay != nil)
    }

    // MARK: Behaviour

    private func queryChanged() {
        switch store.tab {
        case .tasks:
            store.selectedTaskID = store.visibleTasks.first?.id
            store.selectionChanged()
        case .sessions:
            store.searchSessions()
        default: break
        }
    }

    private func tabChanged(_ tab: PaletteTab) {
        store.query = ""
        searchFocused = true
        switch tab {
        case .sessions: store.searchSessions()
        case .cleanup: store.loadCleanup()
        case .settings: store.loadConfig()
        case .tasks: store.selectionChanged()
        }
    }

    /// ⌘← / ⌘→ step through the tabs, wrapping around at either end.
    private func cycleTab(_ delta: Int) {
        let tabs = PaletteTab.allCases
        guard let index = tabs.firstIndex(of: store.tab) else { return }
        store.tab = tabs[(index + delta + tabs.count) % tabs.count]
    }

    private func move(_ delta: Int) {
        switch store.tab {
        case .tasks:
            let ids = store.visibleTasks.map(\.id)
            store.selectedTaskID = step(ids, current: store.selectedTask?.id, delta)
            store.selectionChanged()
        case .sessions:
            store.selectedSessionID = step(store.sessions.map(\.id), current: store.selectedSession?.id, delta)
        case .cleanup:
            store.selectedCleanupID = step(store.visibleCleanup.map(\.id), current: store.selectedCleanupID, delta)
        default: break
        }
    }

    private func step(_ ids: [String], current: String?, _ delta: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        let index = current.flatMap { ids.firstIndex(of: $0) } ?? -1
        return ids[min(max(index + delta, 0), ids.count - 1)]
    }

    /// ↵ opens with the 3-pane layout, ⌘↵ with a single Claude pane (only matters when a workspace is created).
    private func primaryAction(single: Bool = false) {
        switch store.tab {
        case .tasks: if let task = store.selectedTask { store.open(task, single: single) }
        case .sessions: if let session = store.selectedSession { store.resume(session, recreate: !session.cwdExists, single: single) }
        case .cleanup: if !single { NotificationCenter.default.post(name: .wkCleanupToggle, object: nil) }
        default: break
        }
    }

    private func openActions() {
        switch store.tab {
        case .tasks: if let task = store.selectedTask { store.overlay = .actions(taskID: task.id) }
        case .sessions: if let session = store.selectedSession { store.overlay = .sessionActions(sessionID: session.id) }
        default: break
        }
    }

    private func newTask() {
        store.overlay = .newTask(NewTaskSeed(repo: store.selectedTask?.repo))
    }

    private func removeSelected() {
        switch store.tab {
        case .tasks: if let task = store.selectedTask { store.overlay = .remove(taskID: task.id) }
        case .sessions: if let session = store.selectedSession { store.trash(session) }
        default: break
        }
    }

    private func pickSession() {
        if store.tab == .tasks, let task = store.selectedTask { store.overlay = .pickSession(taskID: task.id) }
    }

    private func togglePin() {
        if store.tab == .tasks, let task = store.selectedTask { store.setFlag("pin", task: task, value: !task.pinned) }
    }
}

/// Routes the current overlay to its view.
struct OverlayHost: View {
    let overlay: Overlay

    var body: some View {
        switch overlay {
        case .actions(let taskID): TaskActionsOverlay(taskID: taskID)
        case .sessionActions(let sessionID): SessionActionsOverlay(sessionID: sessionID)
        case .newTask(let seed): NewTaskOverlay(seed: seed)
        case .remove(let taskID): RemoveOverlay(taskID: taskID)
        case .checkout(let taskID, let mode, let session, let single): CheckoutOverlay(taskID: taskID, mode: mode, session: session, single: single)
        case .prompt(let kind): PromptOverlay(kind: kind)
        case .pickSession(let taskID): PickSessionOverlay(taskID: taskID)
        }
    }
}
