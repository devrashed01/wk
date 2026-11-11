import SwiftUI
import WkKit

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, appearance, claude, scanning, repos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .claude: "Claude"
        case .scanning: "Scanning"
        case .repos: "Repos"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .claude: "sparkles"
        case .scanning: "folder.badge.gearshape"
        case .repos: "shippingbox"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .appearance: .pink
        case .claude: .orange
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
        }
        .onAppear { if draft == nil { draft = store.config } }
        .onChange(of: store.config) { _, config in if draft == nil || saveTask == nil { draft = config } }
        .onChange(of: draft) { _, value in scheduleSave(value) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.allCases) { item in
                Button { category = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(item.color.gradient, in: RoundedRectangle(cornerRadius: 6))
                        Text(item.title).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(category == item ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let savedAt {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .id(savedAt)
                    .transition(.opacity)
            }
            Text("~/.config/wk/config.toml").font(.caption2).foregroundStyle(.tertiary)
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
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

private struct GeneralSettings: View {
    @Environment(AppStore.self) private var store
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
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
            LabeledContent("Single Claude pane") {
                Text("⌘↵ instead of ↵").foregroundStyle(.secondary)
            }
            Hint("↵ opens a new workspace with Claude, server and git panes. ⌘↵ opens just Claude. To always use one pane for a repo, see Repos.")
        }
    }
}

private struct ScanningSettings: View {
    @Binding var draft: WkConfig

    var body: some View {
        SettingsPage(category: .scanning, subtitle: "Where wk looks for repos and what it lists.") {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Scan folders", text: Binding(
                    get: { draft.roots.joined(separator: ", ") },
                    set: { draft.roots = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }),
                          prompt: Text("~/code, ~/projects"))
                Hint("Comma separated. Folders that don't exist are skipped.")
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
                        Text(repo.label).font(.system(size: 12, weight: .semibold))
                        Text(repo.name).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(repo.path)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: 220)
            if let repo = selected {
                SettingsPage(category: .repos, subtitle: PathDisplay.collapse(repo)) {
                    RepoEditor(settings: binding(for: repo), baseBranch: draft.baseBranch)
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
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 64)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Hint("One command per line. Empty = automatic: .env* files are copied and the lockfile's install runs (yarn/pnpm/npm).")
        }
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Always use a single Claude pane", isOn: Binding(get: { settings.noLayout ?? false },
                                                                     set: { settings.noLayout = $0 ? true : nil }))
            Hint("Skips the server and git panes for this repo, as if you always pressed ⌘↵.")
        }
    }
}
