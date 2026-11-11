import SwiftUI
import WkKit

/// The hotkey window: search, tabs, list + detail, always-visible key hints, and modal overlays.
struct PaletteView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var store = store
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                hintBar
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))

            if let overlay = store.overlay {
                OverlayHost(overlay: overlay)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            if let toast = store.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.thickMaterial, in: Capsule())
                        .shadow(radius: 6)
                        .padding(.bottom, 44)
                        .onTapGesture { store.toast = nil }
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .background(shortcuts)
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .wkFocusSearch)) { _ in
            searchFocused = false
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: store.overlay) { _, overlay in if overlay == nil { searchFocused = true } }
        .onChange(of: store.query) { _, _ in queryChanged() }
        .onChange(of: store.tab) { _, tab in tabChanged(tab) }
    }

    private var header: some View {
        @Bindable var store = store
        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($searchFocused)
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.return) { primaryAction(); return .handled }
            if !store.snapshot.cmuxRunning && store.snapshot.generatedAt > .distantPast {
                Chip(text: "cmux not running", color: .orange, systemImage: "exclamationmark.triangle")
            }
            Picker("", selection: $store.tab) {
                ForEach(PaletteTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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
        HStack(spacing: 14) {
            switch store.tab {
            case .tasks:
                KeyHint(keys: "↵", label: "Open")
                KeyHint(keys: "⌘K", label: "All actions")
                KeyHint(keys: "⌘N", label: "New task")
                KeyHint(keys: "⌘R", label: "Pick session")
                KeyHint(keys: "⌘⌫", label: "Remove")
                KeyHint(keys: "⌘P", label: "Pin")
            case .sessions:
                KeyHint(keys: "↵", label: "Resume")
                KeyHint(keys: "⌘K", label: "All actions")
                KeyHint(keys: "⌘⌫", label: "Trash")
            case .cleanup:
                KeyHint(keys: "space", label: "Toggle")
                KeyHint(keys: "⌘↵", label: "Remove selected")
            case .settings:
                KeyHint(keys: "⌘S", label: "Save")
            }
            Spacer()
            KeyHint(keys: "⌘1–4", label: "Tabs")
            KeyHint(keys: "esc", label: "Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    /// Invisible buttons that own the ⌘ shortcuts while the palette is key.
    private var shortcuts: some View {
        Group {
            Button("") { store.tab = .tasks }.keyboardShortcut("1", modifiers: .command)
            Button("") { store.tab = .sessions }.keyboardShortcut("2", modifiers: .command)
            Button("") { store.tab = .cleanup }.keyboardShortcut("3", modifiers: .command)
            Button("") { store.tab = .settings }.keyboardShortcut("4", modifiers: .command)
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

    private func move(_ delta: Int) {
        switch store.tab {
        case .tasks:
            let ids = store.visibleTasks.map(\.id)
            store.selectedTaskID = step(ids, current: store.selectedTask?.id, delta)
            store.selectionChanged()
        case .sessions:
            store.selectedSessionID = step(store.sessions.map(\.id), current: store.selectedSession?.id, delta)
        default: break
        }
    }

    private func step(_ ids: [String], current: String?, _ delta: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        let index = current.flatMap { ids.firstIndex(of: $0) } ?? -1
        return ids[min(max(index + delta, 0), ids.count - 1)]
    }

    private func primaryAction() {
        switch store.tab {
        case .tasks: if let task = store.selectedTask { store.open(task) }
        case .sessions: if let session = store.selectedSession { store.resume(session, recreate: !session.cwdExists) }
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
        case .checkout(let taskID, let mode, let session): CheckoutOverlay(taskID: taskID, mode: mode, session: session)
        case .prompt(let kind): PromptOverlay(kind: kind)
        case .pickSession(let taskID): PickSessionOverlay(taskID: taskID)
        }
    }
}
