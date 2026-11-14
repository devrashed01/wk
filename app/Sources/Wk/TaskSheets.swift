import SwiftUI
import WkKit

/// ⌘N: create a branch, in a new worktree or in place, and open it with Claude.
struct NewTaskOverlay: View {
    let seed: NewTaskSeed
    @Environment(AppStore.self) private var store
    @State private var repo = ""
    @State private var from = "base"
    @State private var ref = ""
    @State private var mode = "worktree"
    @State private var name = ""
    @State private var stash = false
    @State private var setup = true
    @State private var startClaude = true
    @State private var refs: RepoRefs?
    @State private var loadError: String?
    @State private var seeded = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        OverlayCard(title: "New task", width: 560) {
            Form {
                LabeledContent("Repo") {
                    SearchableSelect(options: (store.snapshot.repos ?? []).map { .init(value: $0.path, label: "\($0.label)  ·  \($0.name)") },
                                     selection: $repo, searchPrompt: "Search repos…")
                }
                Picker("Start from", selection: $from) {
                    Text("Latest \(refs?.baseBranch ?? "base")").tag("base")
                    Text("Local branch").tag("local")
                    Text("Remote branch").tag("remote")
                    Text("A worktree's HEAD").tag("worktree")
                }
                .pickerStyle(.segmented)
                if from != "base" {
                    LabeledContent(fromLabel) {
                        SearchableSelect(options: refList.map { .init(value: $0, label: PathDisplay.collapse($0)) },
                                         selection: $ref, searchPrompt: "Search \(refList.count) \(from == "worktree" ? "worktrees" : "branches")…")
                    }
                }
                Picker("Where", selection: $mode) {
                    Text("New worktree folder").tag("worktree")
                    Text("Switch main folder").tag("in-place")
                }
                .pickerStyle(.segmented)
                TextField("Branch name", text: $name, prompt: Text("\(refs?.suggestedPrefix ?? "")1234-short-description"))
                    .focused($nameFocused)
                    .onSubmit(create)
                if mode == "worktree" {
                    Toggle("Set up the folder (copy .env files, install dependencies)", isOn: $setup)
                } else {
                    Toggle("Stash uncommitted changes in the main folder", isOn: $stash)
                }
                Toggle("Open Claude in the new workspace", isOn: $startClaude)
                if startClaude {
                    Text(store.config?.autoStartClaude == true
                         ? "Claude starts right away (Settings → Claude)."
                         : "`claude` is typed in the tab; press Enter to start it (Settings → Claude).")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .formStyle(.columns)
            if let preview { Text(preview).font(.system(size: 12)).foregroundStyle(.secondary) }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.red) }
            if let loadError { Text(loadError).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Text("Runs in the background — you can keep working.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.overlay = nil }
                Button("Create & open", action: create)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(problem != nil)
            }
            Text("⌘↵ to create").font(.system(size: 11)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onAppear {
            repo = seed.repo ?? store.snapshot.repos?.first?.path ?? ""
            from = seed.from
            ref = seed.ref ?? ""
            nameFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { nameFocused = true }
            loadRefs()
            DispatchQueue.main.async { seeded = true }
        }
        .onChange(of: repo) { _, _ in ref = ""; loadRefs() }
        .onChange(of: from) { _, _ in if seeded { ref = "" } }
    }

    private var fromLabel: String {
        switch from {
        case "local": "Branch"
        case "remote": "Remote branch"
        default: "Worktree"
        }
    }

    private var refList: [String] {
        guard let refs else { return [] }
        switch from {
        case "local": return refs.local
        case "remote": return refs.remote
        case "worktree": return refs.worktrees
        default: return []
        }
    }

    private var problem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Enter a branch name" }
        if trimmed.contains(" ") { return "Branch names can't contain spaces" }
        if refs?.local.contains(trimmed) == true { return "\(trimmed) already exists" }
        if from != "base" && ref.isEmpty { return "Choose what to start from" }
        return nil
    }

    private var preview: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !repo.isEmpty else { return nil }
        if mode == "in-place" { return "The main folder \(PathDisplay.collapse(repo)) switches to \(trimmed)." }
        let slug = trimmed.replacingOccurrences(of: "/", with: "-")
        return "Folder: \(PathDisplay.collapse(repo))-\(slug)"
    }

    private func loadRefs() {
        guard !repo.isEmpty else { return }
        let current = repo
        Task {
            do {
                let loaded = try await store.repoRefs(current)
                if current == repo {
                    refs = loaded
                    loadError = nil
                    if name.isEmpty, !loaded.suggestedPrefix.isEmpty { name = loaded.suggestedPrefix }
                }
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func create() {
        guard problem == nil else { return }
        store.createTask(AppStore.NewTaskArgs(
            repo: repo, name: name.trimmingCharacters(in: .whitespaces), from: from, ref: ref.isEmpty ? nil : ref,
            mode: mode, stash: stash, setup: setup, open: startClaude ? nil : "none"))
    }
}

/// ⌘⌫: show what removing a task would touch, with safe defaults and a typed confirmation when work would be lost.
struct RemoveOverlay: View {
    let taskID: String
    @Environment(AppStore.self) private var store
    @State private var plan: RemovePlan?
    @State private var options: [String: Bool] = [:]
    @State private var confirm = ""
    @State private var error: String?

    var body: some View {
        OverlayCard(title: "Remove \(store.task(taskID)?.displayName ?? "")", width: 560) {
            if let plan {
                facts(plan)
                Divider()
                ForEach(RemoveOptionKey.allCases, id: \.rawValue) { key in
                    if let option = plan.options[key.rawValue] {
                        VStack(alignment: .leading, spacing: 1) {
                            Toggle(key.label, isOn: Binding(get: { options[key.rawValue] ?? false }, set: { options[key.rawValue] = $0 }))
                                .toggleStyle(.checkbox)
                                .disabled(!option.available)
                            if let reason = option.reason {
                                Text(reason).font(.system(size: 13)).foregroundStyle(option.available ? .orange : .secondary).padding(.leading, 20)
                            }
                        }
                    }
                }
                if let blocked = plan.blocked {
                    Label(blocked, systemImage: "hand.raised.fill").foregroundStyle(.red)
                }
                if losesWork(plan) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Work will be lost. Type **\(plan.task.branch)** to confirm:").font(.callout)
                        TextField(plan.task.branch, text: $confirm).textFieldStyle(.roundedBorder)
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { store.overlay = nil }.keyboardShortcut(.cancelAction)
                    Button("Remove", role: .destructive) {
                        store.applyRemove(taskID: plan.task.id, options: options, confirm: confirm)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!canRemove(plan))
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView("Checking for unpushed and uncommitted work…").frame(maxWidth: .infinity)
            }
        }
        .task {
            do {
                let loaded = try await store.planRemove(taskID)
                plan = loaded
                options = loaded.options.mapValues { $0.available && $0.default }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func facts(_ plan: RemovePlan) -> some View {
        let facts = plan.facts
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            GridRow { Text("Folder").foregroundStyle(.secondary); Text(plan.task.path.map(PathDisplay.collapse) ?? "not checked out") }
            GridRow {
                Text("Uncommitted").foregroundStyle(.secondary)
                Text(facts.dirty == 1 ? "1 file" : "\(facts.dirty) files").foregroundStyle(facts.dirty > 0 ? .orange : .primary)
            }
            GridRow {
                Text("Unpushed").foregroundStyle(.secondary)
                Text(facts.unpushed == 1 ? "1 commit" : "\(facts.unpushed) commits").foregroundStyle(facts.unpushed > 0 ? .orange : .primary)
            }
            GridRow { Text("On origin").foregroundStyle(.secondary); Text(facts.hasRemote ? "yes" : "no") }
            GridRow { Text("Merged").foregroundStyle(.secondary); Text(facts.merged ? "yes" : "no") }
            GridRow { Text("Sessions").foregroundStyle(.secondary); Text("\(facts.sessions)" + (facts.liveSessions > 0 ? " (\(facts.liveSessions) running — kept)" : "")) }
            GridRow { Text("cmux").foregroundStyle(.secondary); Text(facts.workspace?.title ?? "not open") }
        }
    }

    private func losesWork(_ plan: RemovePlan) -> Bool {
        (options[RemoveOptionKey.removeWorktree.rawValue] == true && plan.facts.dirty > 0)
            || (options[RemoveOptionKey.deleteBranch.rawValue] == true && plan.facts.unpushed > 0)
    }

    private func canRemove(_ plan: RemovePlan) -> Bool {
        guard plan.blocked == nil, options.values.contains(true) else { return false }
        return !losesWork(plan) || confirm == plan.task.branch
    }
}
