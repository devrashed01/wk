import SwiftUI
import WkKit

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, appearance, claude, layout, scanning, repos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .claude: "Claude"
        case .layout: "Layout"
        case .scanning: "Scanning"
        case .repos: "Repos"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .claude: "sparkles"
        case .layout: "rectangle.split.2x1"
        case .scanning: "folder.badge.gearshape"
        case .repos: "shippingbox"
        }
    }

    /// Words that find this page from the search field (titles of its settings plus synonyms).
    var keywords: String {
        switch self {
        case .general: "hotkey shortcut option space open launch login startup notify notification alert cmux terminal iterm fallback update version"
        case .appearance: "blur backdrop dim dimming dark transparency look theme"
        case .claude: "start claude automatically auto resume tokens single pane zsh"
        case .layout: "layout panes pane split grid columns rows tabs arrangement main size server git shell command workspace"
        case .scanning: "scan folders roots base branch strip prefix label recent days"
        case .repos: "repo repository server command dev base branch setup install env worktree single pane layout"
        }
    }

    func matches(_ query: String) -> Bool {
        let haystack = (title + " " + keywords).lowercased()
        return query.lowercased().split(separator: " ").allSatisfy { haystack.contains($0) }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .appearance: .pink
        case .claude: .orange
        case .layout: .purple
        case .scanning: .blue
        case .repos: .green
        }
    }
}

/// Settings tab: a category sidebar and one short page per category. Every change applies at once;
/// config.toml edits are debounced and written in the background.
struct SettingsPane: View {
    @Environment(AppStore.self) private var store
    @AppStorage("settingsCategory") private var category: SettingsCategory = .general
    @State private var draft: WkConfig?
    @State private var saveTask: Task<Void, Never>?
    @State private var savedAt: Date?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Spacer().frame(width: 24)
            Group {
                if let draft = Binding($draft) {
                    page(draft)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // End the page above the shortcut bar, so a long page (Layout) scrolls instead of hiding its last rows.
            .padding(.bottom, 56)
        }
        .onAppear { if draft == nil { draft = store.config } }
        .onChange(of: store.config) { _, config in if draft == nil || saveTask == nil { draft = config } }
        .onChange(of: draft) { _, value in scheduleSave(value) }
        .onChange(of: store.query) { _, query in
            // Typing in the search field jumps to the first page that has a matching setting.
            guard !query.isEmpty, !category.matches(query),
                  let first = SettingsCategory.allCases.first(where: { $0.matches(query) }) else { return }
            category = first
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.allCases) { item in
                let dimmed = !store.query.isEmpty && !item.matches(store.query)
                Button { category = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(item.color.gradient, in: RoundedRectangle(cornerRadius: 6))
                        Text(item.title).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(category == item ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .opacity(dimmed ? 0.35 : 1)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let savedAt {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .id(savedAt)
                    .transition(.opacity)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: PathDisplay.configFile)])
            } label: {
                Label(PathDisplay.collapse(PathDisplay.configFile), systemImage: "doc.text").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show the config file in Finder")
        }
        .padding(12)
        .frame(width: 200)
    }

    @ViewBuilder
    private func page(_ draft: Binding<WkConfig>) -> some View {
        switch category {
        case .general: GeneralSettings()
        case .appearance: AppearanceSettings()
        case .claude: ClaudeSettings(draft: draft)
        case .layout: LayoutSettings(draft: draft)
        case .scanning: ScanningSettings(draft: draft)
        case .repos: RepoSettingsPage(draft: draft)
        }
    }

    private func scheduleSave(_ value: WkConfig?) {
        guard let value, value != store.config else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            if await store.saveConfigQuietly(value) {
                withAnimation { savedAt = Date() }
            }
            saveTask = nil
        }
    }
}

/// Shared page chrome: big title, short subtitle, grouped form.
private struct SettingsPage<Content: View>: View {
    let category: SettingsCategory
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            Section {
                content
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                .textCase(nil)
                .padding(.bottom, 8)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

private struct GeneralSettings: View {
    @Environment(AppStore.self) private var store
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var fallbackTerminal = FallbackTerminal.current
    @State private var hotkey = UserDefaults.standard.string(forKey: "hotkey") ?? HotKey.choices[0].id

    var body: some View {
        @Bindable var store = store
        SettingsPage(category: .general, subtitle: "How wk starts and gets your attention.") {
            Picker("Open wk with", selection: $hotkey) {
                ForEach(HotKey.choices) { Text($0.label).tag($0.id) }
            }
            .onChange(of: hotkey) { _, value in
                UserDefaults.standard.set(value, forKey: "hotkey")
                (NSApp.delegate as? AppDelegate)?.applyHotKey()
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, value in
                    do { try LaunchAtLogin.set(value) } catch { store.show(error); launchAtLogin = LaunchAtLogin.isEnabled }
                }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Notify when Claude finishes and waits for you", isOn: $store.notifyWhenWaiting)
                Hint("Off by default because cmux can already notify you. Background actions (create, remove) always notify when wk is closed.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Picker("Without cmux, open tasks in", selection: $fallbackTerminal) {
                    ForEach(FallbackTerminal.allCases) { option in
                        Text(option == .auto ? "Automatic (\(FallbackTerminal.auto.resolved.label))" : option.label).tag(option)
                    }
                }
                .onChange(of: fallbackTerminal) { _, value in FallbackTerminal.current = value }
                Hint("Used when cmux isn't installed or doesn't start. The task's folder opens in a new window with Claude running.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Check for updates", isOn: $store.checkForUpdates)
                Hint(store.updateVersion.map { "Version \($0) is available — you have \(store.currentVersion). Click the orange chip at the top left to update." }
                     ?? "You have \(store.currentVersion). Once a day wk asks GitHub for the newest release and shows a chip when there is one. Nothing is installed automatically.")
            }
        }
    }
}

private struct AppearanceSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        SettingsPage(category: .appearance, subtitle: "wk covers the screen while it's open. Changes show up live behind this page.") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Blur the desktop behind wk", isOn: $store.blurBackdrop)
                Hint("Frosted, like Spotlight. Off shows the desktop sharp, only dimmed.")
            }
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Backdrop dimming") {
                    Text("\(Int((store.backdropOpacity * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $store.backdropOpacity, in: 0...0.9) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "sun.max").foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "moon.fill").foregroundStyle(.secondary)
                }
                .labelsHidden()
            }
        }
    }
}

private struct ClaudeSettings: View {
    @Binding var draft: WkConfig

    var body: some View {
        SettingsPage(category: .claude, subtitle: "What happens in the cmux tab when wk opens a task or a session.") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Start Claude automatically", isOn: Binding(
                    get: { draft.autoStartClaude ?? false },
                    set: { draft.autoStartClaude = $0 ? true : nil }))
                Hint("Off: wk types `claude` or `claude --resume …` in the tab and you press Enter to run it. Resuming re-reads the whole conversation, so it costs tokens. Needs zsh; in other shells Claude always starts.")
            }
            Hint("Tip: ↵ opens the panes from Settings → Layout; ⌘↵ opens Claude only. To always open Claude only for a repo, use Settings → Repos.")
        }
    }
}

private struct ScanningSettings: View {
    @Binding var draft: WkConfig

    var body: some View {
        SettingsPage(category: .scanning, subtitle: "Where wk looks for repos and what it lists.") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Scan folders")
                ForEach(Array(draft.roots.enumerated()), id: \.offset) { index, root in
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.blue)
                        Text(PathDisplay.collapse(PathDisplay.expand(root))).lineLimit(1).truncationMode(.middle)
                        if !FileManager.default.fileExists(atPath: PathDisplay.expand(root)) {
                            Chip(text: "not found", color: .orange)
                        }
                        Spacer()
                        Button { draft.roots.remove(at: index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Stop scanning this folder")
                    }
                    .padding(.vertical, 2)
                }
                if draft.roots.isEmpty {
                    Text("No folders yet — wk has nothing to list until you add the folder your repos live in.")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
                Button {
                    PaletteController.shared.chooseFolder { url in
                        let path = PathDisplay.collapse(url.path)
                        if !draft.roots.contains(path) { draft.roots.append(path) }
                    }
                } label: {
                    Label("Add folder…", systemImage: "plus")
                }
                Hint("wk finds the git repos inside these folders, including nested ones.")
            }
            TextField("Default base branch", text: $draft.baseBranch, prompt: Text("auto-detect (origin/HEAD, main, master)"))
            VStack(alignment: .leading, spacing: 4) {
                TextField("Strip from repo labels", text: Binding(
                    get: { (draft.labelStripPrefixes ?? []).joined(separator: ", ") },
                    set: { text in
                        let prefixes = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        draft.labelStripPrefixes = prefixes.isEmpty ? nil : prefixes
                    }), prompt: Text("acme-"))
                Hint("With acme-, the repo acme-web shows as WEB.")
            }
            Stepper("Recent branches: last \(draft.recentDays) days", value: $draft.recentDays, in: 7...365, step: 7)
        }
    }
}

private struct RepoSettingsPage: View {
    @Binding var draft: WkConfig
    @Environment(AppStore.self) private var store
    @State private var selected: String?

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selected) {
                ForEach(store.snapshot.repos ?? []) { repo in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(repo.label).font(.system(size: 13, weight: .semibold))
                        Text(repo.name).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .tag(repo.path)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: 220)
            if let repo = selected {
                SettingsPage(category: .repos, subtitle: PathDisplay.collapse(repo)) {
                    RepoEditor(settings: binding(for: repo), baseBranch: draft.baseBranch, globalLayout: draft.layout ?? .standard)
                }
            } else {
                EmptyState(symbol: "shippingbox", title: "Choose a repo", subtitle: "Set its server command, base branch, worktree setup and layout.")
            }
        }
        .onAppear { if selected == nil { selected = store.snapshot.repos?.first?.path } }
    }

    /// Repo keys in the config use ~ paths, like the Go core.
    private func binding(for repo: String) -> Binding<RepoSettings> {
        let key = PathDisplay.collapse(repo)
        return Binding(
            get: { draft.repos?[key] ?? RepoSettings() },
            set: { value in
                var repos = draft.repos ?? [:]
                repos[key] = value
                draft.repos = repos
            })
    }
}

private struct RepoEditor: View {
    @Binding var settings: RepoSettings
    let baseBranch: String
    let globalLayout: LayoutConfig

    var body: some View {
        TextField("Server command", text: Binding(get: { settings.serverCmd ?? "" },
                                                  set: { settings.serverCmd = $0.isEmpty ? nil : $0 }),
                  prompt: Text("e.g. yarn dev"))
        TextField("Base branch", text: Binding(get: { settings.baseBranch ?? "" },
                                               set: { settings.baseBranch = $0.isEmpty ? nil : $0 }),
                  prompt: Text(baseBranch.isEmpty ? "auto-detect" : baseBranch))
        VStack(alignment: .leading, spacing: 4) {
            Text("Setup steps for new worktrees")
            TextEditor(text: Binding(get: { (settings.postWorktree ?? []).joined(separator: "\n") },
                                     set: { text in
                                         let lines = text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                                         settings.postWorktree = lines.isEmpty ? nil : lines
                                     }))
                .font(.system(size: 13, design: .monospaced))
                .frame(height: 64)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Hint("One command per line. Empty = automatic: .env* files are copied and the lockfile's install runs (yarn/pnpm/npm).")
        }
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Always open Claude only (no other panes)", isOn: Binding(get: { settings.noLayout ?? false },
                                                                     set: { settings.noLayout = $0 ? true : nil }))
            Hint("Skips the other panes for this repo, as if you always pressed ⌘↵.")
        }
        if settings.noLayout != true {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Use a different layout for this repo", isOn: Binding(get: { settings.layout != nil },
                                                                             set: { settings.layout = $0 ? globalLayout : nil }))
                Hint("Off: this repo uses the layout from Settings → Layout.")
            }
            if settings.layout != nil {
                LayoutEditor(layout: Binding(get: { settings.layout ?? globalLayout }, set: { settings.layout = $0 }))
            }
        }
    }
}
