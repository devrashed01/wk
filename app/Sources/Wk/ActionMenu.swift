import SwiftUI
import WkKit

struct ActionItem: Identifiable {
    let id: String
    let section: String
    let title: String
    let symbol: String
    var hint: String = ""
    var destructive = false
    let perform: () -> Void
}

/// ⌘K: every action for the selected row, searchable, arrow keys + return.
struct ActionMenuOverlay: View {
    let title: String
    let items: [ActionItem]
    @State private var filter = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var visible: [ActionItem] {
        let terms = filter.lowercased().split(separator: " ")
        return items.filter { item in terms.allSatisfy { (item.section + " " + item.title).lowercased().contains($0) } }
    }

    var body: some View {
        OverlayCard(title: title, width: 460) {
            TextField("Type to filter…", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.10)))
                .focused($focused)
                .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                .onKeyPress(.downArrow) { selection = min(selection + 1, visible.count - 1); return .handled }
                .onKeyPress(.return) { run(selection); return .handled }
                .onChange(of: filter) { _, _ in selection = 0 }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        let list = visible
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || list[index - 1].section != item.section {
                                Text(item.section.uppercased())
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    .padding(.top, index == 0 ? 0 : 8).padding(.leading, 8)
                            }
                            HStack {
                                Image(systemName: item.symbol).frame(width: 18)
                                Text(item.title)
                                Spacer()
                                if !item.hint.isEmpty { Text(item.hint).font(.system(size: 12)).foregroundStyle(.secondary) }
                            }
                            .foregroundStyle(item.destructive ? Theme.danger : .primary)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(index == selection ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .onTapGesture { run(index) }
                            .id(item.id)
                        }
                    }
                }
                .frame(maxHeight: 480)
                .onChange(of: selection) { _, index in
                    if visible.indices.contains(index) { proxy.scrollTo(visible[index].id) }
                }
            }
        }
        // The overlay often opens mid key-press (↵ in the search field), when a plain focus request is
        // dropped; ask again after the event finishes, and once more after the overlay has settled.
        .task {
            focused = true
            await Task.yield()
            focused = true
            try? await Task.sleep(for: .milliseconds(80))
            focused = true
        }
    }

    private func run(_ index: Int) {
        guard visible.indices.contains(index) else { return }
        visible[index].perform()
    }
}

struct TaskActionsOverlay: View {
    let taskID: String
    @Environment(AppStore.self) private var store

    var body: some View {
        if let task = store.task(taskID) {
            ActionMenuOverlay(title: task.displayName, items: items(task))
        }
    }

    private func items(_ task: WkTask) -> [ActionItem] {
        let close = { store.overlay = nil }
        var list: [ActionItem] = [
            ActionItem(id: "open", section: "Open", title: task.sessions.isEmpty ? "Open (start Claude)" : "Jump / resume latest session", symbol: "arrow.right.circle", hint: "↵") { close(); store.open(task) },
        ]
        if !task.sessions.isEmpty {
            list.append(ActionItem(id: "pick", section: "Open", title: "Resume a specific session…", symbol: "list.bullet", hint: "⌘R") { store.overlay = .pickSession(taskID: task.id) })
        }
        list += [
            ActionItem(id: "fresh", section: "Open", title: "New Claude session here", symbol: "plus.bubble") { close(); store.open(task, mode: "new") },
            ActionItem(id: "noclaude", section: "Open", title: "Open without Claude", symbol: "terminal") { close(); store.open(task, mode: "none") },
            ActionItem(id: "newws", section: "Open", title: "Open in a new cmux workspace", symbol: "rectangle.badge.plus") { close(); store.open(task, newWorkspace: true) },
            ActionItem(id: "single", section: "Open", title: "Open with a single Claude pane", symbol: "rectangle", hint: "⌘↵") { close(); store.open(task, single: true) },
        ]
        if task.hasFolder {
            list.append(ActionItem(id: "switch", section: "Branch", title: "Switch this folder to another branch…", symbol: "arrow.triangle.branch") {
                store.overlay = .prompt(.switchBranch(taskID: task.id, repo: task.repo))
            })
        }
        list += [
            ActionItem(id: "branchfrom", section: "Branch", title: "New branch from \(task.branch)…", symbol: "plus.square.on.square") {
                store.overlay = .newTask(NewTaskSeed(repo: task.repo, from: "local", ref: task.branch))
            },
            ActionItem(id: "copy", section: "Branch", title: "Copy branch name", symbol: "doc.on.doc") { close(); store.copy(task.branch, label: "branch name") },
            ActionItem(id: "pull", section: "Branch", title: task.hasFolder ? "Pull (fast-forward)" : "Fetch", symbol: "arrow.down.circle") {
                close(); store.taskCommand("pull", ["task": task.id], title: "Pulling \(task.branch)")
            },
        ]
        if !task.isBase && !task.detached {
            list.append(ActionItem(id: "rename", section: "Branch", title: "Rename branch…", symbol: "pencil") {
                store.overlay = .prompt(.renameBranch(taskID: task.id, current: task.branch))
            })
        }
        if !task.hasFolder && !task.detached {
            list.append(ActionItem(id: "wt", section: "Worktree", title: "Open in a new worktree folder", symbol: "folder.badge.plus") { close(); store.open(task, via: "worktree") })
            list.append(ActionItem(id: "sw", section: "Worktree", title: "Switch the main folder to this branch", symbol: "arrow.uturn.right") { close(); store.open(task, via: "switch") })
        }
        if let path = task.path, !path.isEmpty {
            list.append(ActionItem(id: "wtfrom", section: "Worktree", title: "New worktree from this folder's HEAD…", symbol: "folder.badge.plus") {
                store.overlay = .newTask(NewTaskSeed(repo: task.repo, from: "worktree", ref: path))
            })
            list.append(ActionItem(id: "reveal", section: "Worktree", title: "Reveal folder in Finder", symbol: "folder") { close(); store.reveal(path) })
            list.append(ActionItem(id: "copypath", section: "Worktree", title: "Copy folder path", symbol: "doc.on.clipboard") { close(); store.copy(path, label: "path") })
        }
        list.append(ActionItem(id: "wtother", section: "Worktree", title: "Worktree for another existing branch…", symbol: "folder.badge.questionmark") {
            store.overlay = .prompt(.worktreeForBranch(repo: task.repo))
        })
        list += [
            ActionItem(id: "pin", section: "Organize", title: task.pinned ? "Unpin" : "Pin to top", symbol: task.pinned ? "pin.slash" : "pin", hint: "⌘P") {
                close(); store.setFlag("pin", task: task, value: !task.pinned)
            },
            ActionItem(id: "note", section: "Organize", title: task.note?.isEmpty == false ? "Edit note…" : "Add note…", symbol: "note.text") {
                store.overlay = .prompt(.note(taskID: task.id, current: task.note ?? ""))
            },
            ActionItem(id: "hide", section: "Organize", title: task.hidden ? "Show in list again" : "Hide from list", symbol: task.hidden ? "eye" : "eye.slash") {
                close(); store.setFlag("hide", task: task, value: !task.hidden)
            },
            ActionItem(id: "remove", section: "Remove", title: "Remove worktree / branch / sessions…", symbol: "trash", hint: "⌘⌫", destructive: true) {
                store.overlay = .remove(taskID: task.id)
            },
        ]
        return list
    }
}

struct SessionActionsOverlay: View {
    let sessionID: String
    @Environment(AppStore.self) private var store

    var body: some View {
        if let session = store.session(sessionID) {
            ActionMenuOverlay(title: session.displayTitle, items: items(session))
        }
    }

    private func items(_ session: Session) -> [ActionItem] {
        let close = { store.overlay = nil }
        var list: [ActionItem] = []
        if session.cwdExists {
            list.append(ActionItem(id: "resume", section: "Open", title: session.isLive ? "Jump to running session" : "Resume", symbol: "arrow.right.circle", hint: "↵") { close(); store.resume(session) })
            list.append(ActionItem(id: "resumenew", section: "Open", title: "Resume in a new cmux workspace", symbol: "rectangle.badge.plus") { close(); store.resume(session, newWorkspace: true) })
            list.append(ActionItem(id: "resumesingle", section: "Open", title: "Resume with a single Claude pane", symbol: "rectangle", hint: "⌘↵") { close(); store.resume(session, single: true) })
        } else {
            list.append(ActionItem(id: "recreate", section: "Open", title: "Recreate its folder and resume", symbol: "arrow.counterclockwise.circle", hint: "↵") { close(); store.resume(session, recreate: true) })
        }
        if let taskID = session.taskId, store.task(taskID) != nil {
            list.append(ActionItem(id: "task", section: "Open", title: "Show its task", symbol: "list.bullet.rectangle") {
                close(); store.tab = .tasks; store.selectedTaskID = taskID; store.selectionChanged()
            })
        }
        list += [
            ActionItem(id: "rename", section: "Organize", title: "Rename (in wk)…", symbol: "pencil") {
                store.overlay = .prompt(.renameSession(sessionID: session.id, current: session.alias ?? session.title))
            },
            ActionItem(id: "copyid", section: "Organize", title: "Copy resume command", symbol: "doc.on.doc") {
                close(); store.copy("cd '\(session.cwd)' && claude --resume \(session.id)", label: "resume command")
            },
            ActionItem(id: "trash", section: "Remove", title: session.trashed == true ? "Restore from trash" : "Move to trash", symbol: session.trashed == true ? "arrow.uturn.backward" : "trash",
                       hint: "⌘⌫", destructive: session.trashed != true) { close(); store.trash(session) },
        ]
        return list
    }
}

/// Branch without a folder: ask how to check it out.
struct CheckoutOverlay: View {
    let taskID: String
    let mode: String
    let session: String?
    let single: Bool
    @Environment(AppStore.self) private var store

    /// Same keyboard list as ⌘K: ↑↓ to pick, ↵ to open, esc to cancel.
    var body: some View {
        if let task = store.task(taskID) {
            ActionMenuOverlay(title: "\(task.branch) has no folder. Open it how?", items: [
                ActionItem(id: "worktree", section: "Recommended: keeps the main folder untouched",
                           title: "New worktree folder  ·  \(PathDisplay.collapse(task.repo))-…", symbol: "folder.badge.plus", hint: "↵") {
                    choose(task, "worktree")
                },
                ActionItem(id: "switch", section: "Main folder",
                           title: "Switch the main \(task.repoLabel) folder to this branch", symbol: "arrow.uturn.right") {
                    choose(task, "switch")
                },
            ])
        }
    }

    private func choose(_ task: WkTask, _ via: String) {
        store.overlay = nil
        store.open(task, mode: mode, session: session, via: via, single: single)
    }
}

struct PickSessionOverlay: View {
    let taskID: String
    @Environment(AppStore.self) private var store

    var body: some View {
        if let task = store.task(taskID) {
            ActionMenuOverlay(title: "Resume which session? — \(task.branch)", items: task.sessions.map { session in
                ActionItem(id: session.id, section: session.primary == false ? "Also touched this branch" : "Sessions",
                           title: session.displayTitle, symbol: session.isLive ? "play.circle.fill" : "bubble.left",
                           hint: RelativeTime.short(session.last)) {
                    store.overlay = nil
                    store.open(task, session: session.id)
                }
            })
        }
    }
}

/// Small text / branch prompts.
struct PromptOverlay: View {
    let kind: PromptKind
    @Environment(AppStore.self) private var store
    @State private var text = ""
    @State private var refs: RepoRefs?
    @State private var stash = false
    @FocusState private var focused: Bool

    var body: some View {
        OverlayCard(title: title) {
            if needsBranchList {
                TextField("Filter branches…", text: $text).textFieldStyle(.roundedBorder).focused($focused)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(branchOptions, id: \.self) { branch in
                            Button { submit(branch) } label: {
                                Text(branch).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 260)
                if case .switchBranch = kind {
                    Toggle("Stash uncommitted changes first", isOn: $stash).toggleStyle(.checkbox)
                }
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { submit(text) }
                HStack {
                    Spacer()
                    Button("Cancel") { store.overlay = nil }
                    Button("Save") { submit(text) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear {
            focused = true
            switch kind {
            case .renameBranch(_, let current), .note(_, let current), .renameSession(_, let current): text = current
            case .switchBranch(_, let repo), .worktreeForBranch(let repo):
                Task { refs = try? await store.repoRefs(repo) }
            }
        }
    }

    private var needsBranchList: Bool {
        switch kind {
        case .switchBranch, .worktreeForBranch: true
        default: false
        }
    }

    private var branchOptions: [String] {
        guard let refs else { return [] }
        let all = refs.local + refs.remote.filter { remote in !refs.local.contains(String(remote.drop(while: { $0 != "/" }).dropFirst())) }
        let terms = text.lowercased().split(separator: " ")
        return Array(all.filter { branch in terms.allSatisfy { branch.lowercased().contains($0) } }.prefix(200))
    }

    private var title: String {
        switch kind {
        case .renameBranch: "Rename branch"
        case .note: "Note for this task"
        case .renameSession: "Rename session (shown in wk only)"
        case .switchBranch: "Switch folder to branch"
        case .worktreeForBranch: "New worktree for existing branch"
        }
    }

    private var placeholder: String {
        switch kind {
        case .note: "e.g. waiting for backend, QA on staging…"
        default: "Name"
        }
    }

    private func submit(_ value: String) {
        store.overlay = nil
        switch kind {
        case .renameBranch(let taskID, _):
            store.taskCommand("rename_branch", ["task": taskID, "new": value], title: "Renaming branch")
        case .note(let taskID, _):
            store.taskCommand("note", ["task": taskID, "text": value], title: "Saving note")
        case .renameSession(let sessionID, _):
            store.taskCommand("session_rename", ["session": sessionID, "text": value], title: "Renaming session")
        case .switchBranch(let taskID, _):
            struct Args: Encodable { var task: String; var branch: String; var stash: Bool }
            let stash = stash
            store.run("Switching to \(value)") { client, _ in
                try await client.call("switch", Args(task: taskID, branch: value, stash: stash), as: Message.self).message
            }
        case .worktreeForBranch(let repo):
            store.run("Creating worktree for \(value)", notify: true) { client, progress in
                let result = try await client.call("worktree_add", ["repo": repo, "branch": value], as: NewTaskResult.self, progress: progress)
                return "Worktree ready at \(PathDisplay.collapse(result.path)) — press ↵ on it to open"
            }
        }
    }
}
