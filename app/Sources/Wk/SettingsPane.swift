import SwiftUI
import WkKit

struct SettingsPane: View {
    @Environment(AppStore.self) private var store
    @State private var draft: WkConfig?
    @State private var selectedRepo: String?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var hotkey = UserDefaults.standard.string(forKey: "hotkey") ?? HotKey.choices[0].id

    var body: some View {
        @Bindable var store = store
        Group {
            if let draft = Binding($draft) {
                Form {
                    Section("App") {
                        Picker("Hotkey", selection: $hotkey) {
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
                        Toggle("Notify when Claude finishes and waits for you", isOn: $store.notifyWhenWaiting)
                        Text("Off by default because cmux can already notify you. Background actions (create, remove) always notify when the window is closed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Scanning") {
                        TextField("Scan folders (comma separated)", text: Binding(
                            get: { draft.wrappedValue.roots.joined(separator: ", ") },
                            set: { draft.wrappedValue.roots = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                        TextField("Default base branch", text: draft.baseBranch, prompt: Text("auto-detect (origin/HEAD, main, master)"))
                        TextField("Strip from repo labels (comma separated)", text: Binding(
                            get: { (draft.wrappedValue.labelStripPrefixes ?? []).joined(separator: ", ") },
                            set: { text in
                                let prefixes = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                draft.wrappedValue.labelStripPrefixes = prefixes.isEmpty ? nil : prefixes
                            }), prompt: Text("e.g. acme-  →  acme-web shows as WEB"))
                        Stepper("Show branches active in the last \(draft.wrappedValue.recentDays) days", value: draft.recentDays, in: 7...365, step: 7)
                    }
                    Section("Per repo") {
                        Picker("Repo", selection: $selectedRepo) {
                            Text("Choose…").tag(String?.none)
                            ForEach(store.snapshot.repos ?? []) { repo in Text("\(repo.label)  ·  \(repo.name)").tag(String?.some(repo.path)) }
                        }
                        if let repo = selectedRepo {
                            repoEditor(repo, draft: draft)
                        }
                    }
                }
                .formStyle(.grouped)
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Text(store.config == draft.wrappedValue ? "Saved to ~/.config/wk/config.toml" : "Unsaved changes")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Revert") { self.draft = store.config }.disabled(store.config == draft.wrappedValue)
                        Button("Save") { store.saveConfig(draft.wrappedValue) }
                            .keyboardShortcut("s", modifiers: .command)
                            .disabled(store.config == draft.wrappedValue)
                    }
                    .padding(10)
                    .background(.bar)
                }
            } else {
                ProgressView()
            }
        }
        .onAppear { draft = store.config }
        .onChange(of: store.config) { _, config in if draft == nil || draft == store.config { draft = config } }
    }

    /// Repo keys in the config use ~ paths, like the Go core.
    private func key(_ path: String) -> String { PathDisplay.collapse(path) }

    @ViewBuilder
    private func repoEditor(_ repo: String, draft: Binding<WkConfig>) -> some View {
        let settings = Binding<RepoSettings>(
            get: { draft.wrappedValue.repos?[key(repo)] ?? RepoSettings() },
            set: { value in
                var repos = draft.wrappedValue.repos ?? [:]
                repos[key(repo)] = value
                draft.wrappedValue.repos = repos
            })
        TextField("Server command (server pane)", text: Binding(get: { settings.wrappedValue.serverCmd ?? "" },
                                                                set: { settings.wrappedValue.serverCmd = $0.isEmpty ? nil : $0 }),
                  prompt: Text("e.g. yarn dev"))
        TextField("Base branch", text: Binding(get: { settings.wrappedValue.baseBranch ?? "" },
                                               set: { settings.wrappedValue.baseBranch = $0.isEmpty ? nil : $0 }),
                  prompt: Text(draft.wrappedValue.baseBranch.isEmpty ? "auto-detect" : draft.wrappedValue.baseBranch))
        VStack(alignment: .leading) {
            Text("Setup steps for new worktrees (one per line)")
            TextEditor(text: Binding(get: { (settings.wrappedValue.postWorktree ?? []).joined(separator: "\n") },
                                     set: { text in
                                         let lines = text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                                         settings.wrappedValue.postWorktree = lines.isEmpty ? nil : lines
                                     }))
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 54)
            Text("Empty = automatic: .env* files are copied and the lockfile's install runs (yarn/pnpm/npm).")
                .font(.caption).foregroundStyle(.secondary)
        }
        Toggle("Single pane (no server/git split)", isOn: Binding(get: { settings.wrappedValue.noLayout ?? false },
                                                                set: { settings.wrappedValue.noLayout = $0 ? true : nil }))
    }
}
