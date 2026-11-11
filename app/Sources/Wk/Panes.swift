import SwiftUI
import WkKit

// MARK: Tasks

struct TasksPane: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let tasks = store.visibleTasks
        HStack(spacing: 0) {
            if tasks.isEmpty {
                EmptyState(symbol: "tray", title: store.query.isEmpty ? "No tasks yet" : "No matches",
                           subtitle: "Press ⌘N to create a branch or worktree.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(tasks) { task in
                                TaskRow(task: task, selected: task.id == store.selectedTask?.id)
                                    .id(task.id)
                                    .onTapGesture(count: 2) { store.open(task) }
                                    .onTapGesture { select(task) }
                                    .contextMenu { TaskContextMenu(task: task) }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: store.selectedTaskID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
                .frame(width: 470)
                Divider()
                TaskDetailView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { store.selectionChanged() }
    }

    private func select(_ task: WkTask) {
        store.selectedTaskID = task.id
        store.selectionChanged()
    }
}

struct TaskContextMenu: View {
    let task: WkTask
    @Environment(AppStore.self) private var store

    var body: some View {
        Button("Open") { store.open(task) }
        Button("All actions…") { store.overlay = .actions(taskID: task.id) }
        Divider()
        Button(task.pinned ? "Unpin" : "Pin") { store.setFlag("pin", task: task, value: !task.pinned) }
        Button("Copy branch name") { store.copy(task.branch, label: "branch name") }
        Divider()
        Button("Remove…", role: .destructive) { store.overlay = .remove(taskID: task.id) }
    }
}

struct TaskDetailView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let task = store.selectedTask {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(task.repoLabel).font(.caption.bold()).foregroundStyle(.secondary)
                            if let ticket = task.ticket { Chip(text: ticket, color: .blue) }
                            if task.isBase { Chip(text: "base") }
                            if task.merged { Chip(text: "merged", color: .green) }
                            if task.gone { Chip(text: "remote deleted", color: .orange) }
                        }
                        Text(task.branch).font(.title3.weight(.semibold)).textSelection(.enabled)
                        if let note = task.note, !note.isEmpty {
                            Label(note, systemImage: "note.text").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    facts(task)
                    sessions(task)
                    if let detail = store.detail, detail.task.id == task.id {
                        if let changes = detail.changes, !changes.isEmpty {
                            DetailSection(title: "Uncommitted (\(changes.count))") {
                                ForEach(changes.prefix(8), id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)).lineLimit(1) }
                                if changes.count > 8 { Text("… \(changes.count - 8) more").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if let log = detail.log, !log.isEmpty {
                            DetailSection(title: "Commits") {
                                ForEach(log, id: \.self) { Text($0).font(.system(size: 11)).lineLimit(1).foregroundStyle(.secondary) }
                            }
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyState(symbol: "sidebar.right", title: "Select a task")
        }
    }

    private func facts(_ task: WkTask) -> some View {
        DetailSection(title: "Where") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("Folder").foregroundStyle(.secondary)
                    if let path = task.path, !path.isEmpty {
                        Text(PathDisplay.collapse(path) + (task.mainWorktree ? "" : "  (worktree)")).textSelection(.enabled)
                    } else {
                        Text("not checked out — opening will ask how").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("cmux").foregroundStyle(.secondary)
                    if let workspace = task.workspace {
                        Text(workspace.title + ((workspace.ports ?? []).isEmpty ? "" : "  · ports \((workspace.ports ?? []).map(String.init).joined(separator: ", "))"))
                    } else {
                        Text("not open").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Git").foregroundStyle(.secondary)
                    Text("\(task.dirty) changed · ↑\(task.ahead) ↓\(task.behind)" + (task.upstream.map { " · \($0)" } ?? ""))
                }
                if let envs = task.envBranches, !envs.isEmpty {
                    GridRow {
                        Text("Env").foregroundStyle(.secondary)
                        Text(envs.joined(separator: ", ")).lineLimit(2)
                    }
                }
            }
            .font(.system(size: 12))
        }
    }

    private func sessions(_ task: WkTask) -> some View {
        DetailSection(title: "Claude sessions (\(task.sessions.count))") {
            if task.sessions.isEmpty {
                Text("None yet — ↵ starts one in a new workspace.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(task.sessions.prefix(6)) { session in
                Button { store.open(task, session: session.id) } label: {
                    SessionRow(session: session, selected: false, showRepo: false)
                }
                .buttonStyle(.plain)
                .help("Resume this session")
            }
            if task.sessions.count > 6 {
                Button("All \(task.sessions.count) sessions… (⌘R)") { store.overlay = .pickSession(taskID: task.id) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }
}

// MARK: Sessions

struct SessionsPane: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Toggle("Include trash", isOn: $store.includeTrash)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 6)
                    .onChange(of: store.includeTrash) { _, _ in store.searchSessions() }
                if store.sessions.isEmpty {
                    EmptyState(symbol: "bubble.left.and.bubble.right", title: "No sessions match")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(store.sessions) { session in
                                    SessionRow(session: session, selected: session.id == store.selectedSession?.id)
                                        .id(session.id)
                                        .onTapGesture(count: 2) { store.resume(session, recreate: !session.cwdExists) }
                                        .onTapGesture { store.selectedSessionID = session.id }
                                }
                            }
                            .padding(6)
                        }
                        .onChange(of: store.selectedSessionID) { _, id in if let id { proxy.scrollTo(id) } }
                    }
                }
            }
            .frame(width: 470)
            Divider()
            SessionDetailView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SessionDetailView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let session = store.selectedSession {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SessionStateIcon(session: session)
                        Text(session.state.rawValue.capitalized).font(.caption.bold()).foregroundStyle(.secondary)
                    }
                    Text(session.displayTitle).font(.title3.weight(.semibold)).textSelection(.enabled)
                    if let prompt = session.firstPrompt, prompt != session.displayTitle {
                        DetailSection(title: "First prompt") { Text(prompt).font(.callout).foregroundStyle(.secondary) }
                    }
                    DetailSection(title: "Where") {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                            GridRow { Text("Folder").foregroundStyle(.secondary); Text(PathDisplay.collapse(session.cwd) + (session.cwdExists ? "" : "  (deleted)")) }
                            GridRow { Text("Branch").foregroundStyle(.secondary); Text(session.branch) }
                            if let branches = session.branches, branches.count > 1 {
                                GridRow { Text("Also on").foregroundStyle(.secondary); Text(branches.filter { $0 != session.branch }.joined(separator: ", ")).lineLimit(3) }
                            }
                            GridRow { Text("Started").foregroundStyle(.secondary); Text(session.start.formatted(date: .abbreviated, time: .shortened)) }
                            GridRow { Text("Last").foregroundStyle(.secondary); Text(session.last.formatted(date: .abbreviated, time: .shortened)) }
                            GridRow { Text("Prompts").foregroundStyle(.secondary); Text("\(session.prompts)") }
                            GridRow { Text("ID").foregroundStyle(.secondary); Text(session.id).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                        }
                        .font(.system(size: 12))
                    }
                    HStack {
                        Button(session.cwdExists ? "Resume" : "Recreate folder & resume") { store.resume(session, recreate: !session.cwdExists) }
                            .keyboardShortcut(.defaultAction)
                        Button("All actions… ⌘K") { store.overlay = .sessionActions(sessionID: session.id) }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyState(symbol: "sidebar.right", title: "Select a session")
        }
    }
}

// MARK: Cleanup

struct CleanupPane: View {
    @Environment(AppStore.self) private var store
    @State private var selected: Set<String> = []
    @State private var force = false

    var body: some View {
        let items = store.visibleCleanup
        VStack(spacing: 0) {
            if store.cleanupLoading && store.cleanupItems.isEmpty {
                ProgressView("Checking branches for merged, deleted and unpushed work…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                EmptyState(symbol: "sparkles", title: "Nothing to clean up",
                           subtitle: "Merged branches, deleted remotes, missing folders, stale tasks and orphaned sessions show up here.")
            } else {
                List {
                    ForEach(groupedKinds(items), id: \.self) { kind in
                        Section(items.first { $0.kind == kind }?.kindLabel ?? kind) {
                            ForEach(items.filter { $0.kind == kind }) { item in row(item) }
                        }
                    }
                }
                .listStyle(.inset)
                Divider()
                HStack {
                    Button("Select safe") { selected = Set(items.filter(\.safe).map(\.id)) }
                    Button("Select none") { selected = [] }
                    Toggle("Include items with unpushed/uncommitted work", isOn: $force).toggleStyle(.checkbox).font(.caption)
                    Spacer()
                    Text("Removes worktree + local branch. Remote branches are kept.").font(.caption).foregroundStyle(.secondary)
                    Button("Remove \(selected.count) selected", role: .destructive) {
                        store.applyCleanup(ids: Array(selected), force: force)
                        selected = []
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(selected.isEmpty)
                }
                .padding(10)
            }
        }
        .onChange(of: store.cleanupItems) { _, items in
            selected.formIntersection(items.map(\.id))
        }
    }

    private func groupedKinds(_ items: [CleanupItem]) -> [String] {
        ["merged", "gone", "missing_worktree", "stale", "orphan_session"].filter { kind in items.contains { $0.kind == kind } }
    }

    private func row(_ item: CleanupItem) -> some View {
        HStack {
            Toggle("", isOn: Binding(get: { selected.contains(item.id) },
                                     set: { if $0 { selected.insert(item.id) } else { selected.remove(item.id) } }))
                .toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(item.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !item.safe { Chip(text: "\(item.dirty) dirty · \(item.unpushed) unpushed", color: .orange) }
            Text(RelativeTime.short(item.last)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
