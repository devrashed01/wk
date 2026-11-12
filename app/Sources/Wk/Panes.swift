import SwiftUI
import WkKit

// MARK: Tasks

struct TasksPane: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let tasks = store.visibleTasks
        VStack(alignment: .leading, spacing: 10) {
        worktreeToggle
        HStack(spacing: 0) {
            if tasks.isEmpty {
                EmptyState(symbol: "tray", title: store.worktreesOnly ? "No worktrees" : store.query.isEmpty ? "No tasks yet" : "No matches",
                           subtitle: store.worktreesOnly ? "Turn off \"Worktrees only\" to see every task." : "Press ⌘N to create a branch or worktree.")
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
                .frame(minWidth: 420, idealWidth: 600, maxWidth: 680)
                Spacer().frame(width: 40)
                TaskDetailView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        }
        .onAppear { store.selectionChanged() }
    }

    private var worktreeToggle: some View {
        @Bindable var store = store
        return Button {
            store.worktreesOnly.toggle()
            store.selectionChanged()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: store.worktreesOnly ? "checkmark.circle.fill" : "arrow.triangle.branch")
                Text("Worktrees only")
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(store.worktreesOnly ? Color.teal : .secondary)
            .background(store.worktreesOnly ? Color.teal.opacity(0.16) : Color.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(store.worktreesOnly ? Color.teal.opacity(0.4) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .padding(.leading, 6)
        .help("Show only tasks checked out in their own worktree folder")
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
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Chip(text: task.repoLabel)
                            if let ticket = task.ticket { Chip(text: ticket, color: .blue) }
                            if task.isBase { Chip(text: "base") }
                            if task.merged { Chip(text: "merged", color: .green) }
                            if task.gone { Chip(text: "remote deleted", color: .orange) }
                        }
                        Text(task.branch)
                            .font(.system(size: 24, weight: .semibold))
                            .textSelection(.enabled)
                        if let note = task.note, !note.isEmpty {
                            Label(note, systemImage: "note.text").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    actions(task)
                    facts(task)
                    sessions(task)
                    if let detail = store.detail, detail.task.id == task.id {
                        if let changes = detail.changes, !changes.isEmpty {
                            DetailCard(title: "Uncommitted (\(changes.count))") {
                                ForEach(changes.prefix(8), id: \.self) {
                                    Text($0).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                if changes.count > 8 { Text("… \(changes.count - 8) more").font(.system(size: 12)).foregroundStyle(.tertiary) }
                            }
                        }
                        if let log = detail.log, !log.isEmpty {
                            DetailCard(title: "Commits") {
                                ForEach(log, id: \.self) { line in CommitLine(line: line) }
                            }
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyState(symbol: "sidebar.right", title: "Select a task")
        }
    }

    private func actions(_ task: WkTask) -> some View {
        HStack(spacing: 8) {
            Button { store.open(task) } label: { Label("Open", systemImage: "return") }
                .buttonStyle(.borderedProminent)
            Button("Single pane  ⌘↵") { store.open(task, single: true) }
                .buttonStyle(.bordered)
            Button("All actions  ⌘K") { store.overlay = .actions(taskID: task.id) }
                .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    private func facts(_ task: WkTask) -> some View {
        DetailCard(title: "Where") {
            FactRow(label: "Folder") {
                if let path = task.path, !path.isEmpty {
                    Text(PathDisplay.collapse(path) + (task.mainWorktree ? "" : "  (worktree)")).textSelection(.enabled)
                } else {
                    Text("Not checked out").foregroundStyle(.orange)
                }
            }
            if (task.path ?? "").isEmpty && !task.detached {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "folder.badge.questionmark").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This branch has no folder on disk").font(.system(size: 13, weight: .semibold))
                        Text("No worktree or main checkout has \(task.branch) checked out right now. Its worktree may have been removed, or the main folder switched to another branch. The branch and its Claude sessions are still kept.")
                            .foregroundStyle(.secondary)
                        Text("Press ↵ to choose: a new worktree (recommended, leaves your main folder alone) or switch the main folder to this branch.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            FactRow(label: "cmux") {
                if let workspace = task.workspace {
                    Text(workspace.title + ((workspace.ports ?? []).isEmpty ? "" : "  · ports \((workspace.ports ?? []).map(String.init).joined(separator: ", "))"))
                } else {
                    Text("not open").foregroundStyle(.secondary)
                }
            }
            FactRow(label: "Git") {
                Text("\(task.dirty) changed · ↑\(task.ahead) ↓\(task.behind)" + (task.upstream.map { " · \($0)" } ?? ""))
            }
            if let envs = task.envBranches, !envs.isEmpty {
                FactRow(label: "Env") { Text(envs.joined(separator: ", ")).lineLimit(2) }
            }
        }
    }

    private func sessions(_ task: WkTask) -> some View {
        DetailCard(title: "Claude sessions (\(task.sessions.count))") {
            if task.sessions.isEmpty {
                Text("None yet — ↵ starts one in a new workspace.").font(.system(size: 12)).foregroundStyle(.secondary)
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
                    .buttonStyle(.link).font(.system(size: 12))
            }
        }
    }
}

/// "abc1234 message (2 days ago)" with the hash picked out, so the list scans like a git log.
struct CommitLine: View {
    let line: String

    var body: some View {
        let parts = line.split(separator: " ", maxSplits: 1)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(parts.first.map(String.init) ?? "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.accentColor.opacity(0.9))
            Text(parts.count > 1 ? String(parts[1]) : "")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
                HStack {
                    // Same pill language as the cleanup filters, instead of a bare checkbox.
                    Button {
                        store.includeTrash.toggle()
                        store.searchSessions()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: store.includeTrash ? "trash.fill" : "trash")
                            Text("Include trash")
                            if store.includeTrash {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            }
                        }
                        .font(.system(size: 12, weight: store.includeTrash ? .semibold : .regular))
                        .foregroundStyle(store.includeTrash ? .primary : .secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(store.includeTrash ? Color.white.opacity(0.12) : Color.white.opacity(0.04), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(store.includeTrash ? 0.18 : 0.06)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    if store.sessionsLoading {
                        ProgressView().controlSize(.small).padding(.leading, 6)
                    }
                    Spacer()
                }
                .padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 6)
                if store.sessions.isEmpty {
                    if store.sessionsLoading {
                        ProgressView("Searching sessions…").controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        EmptyState(symbol: "bubble.left.and.bubble.right", title: "No sessions match")
                    }
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
            .frame(minWidth: 420, idealWidth: 600, maxWidth: 680)
            Spacer().frame(width: 40)
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
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            SessionStateIcon(session: session)
                            Text(session.state.rawValue.capitalized).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            if session.trashed == true { Chip(text: "in trash", color: .red) }
                        }
                        Text(session.displayTitle)
                            .font(.system(size: 22, weight: .semibold))
                            .textSelection(.enabled)
                        if let prompt = session.firstPrompt, prompt != session.displayTitle {
                            Text(prompt).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        if session.trashed == true {
                            Button { store.trash(session) } label: {
                                Label("Restore from trash  ⌘⌫", systemImage: "arrow.uturn.backward")
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button { store.resume(session, recreate: !session.cwdExists) } label: {
                                Label(session.cwdExists ? "Resume" : "Recreate folder & resume", systemImage: "return")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button("All actions  ⌘K") { store.overlay = .sessionActions(sessionID: session.id) }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    DetailCard(title: "Where") {
                        FactRow(label: "Folder") { Text(PathDisplay.collapse(session.cwd) + (session.cwdExists ? "" : "  (deleted)")).textSelection(.enabled) }
                        FactRow(label: "Branch") { Text(session.branch) }
                        if let branches = session.branches, branches.count > 1 {
                            FactRow(label: "Also on") { Text(branches.filter { $0 != session.branch }.joined(separator: ", ")).lineLimit(3) }
                        }
                    }
                    DetailCard(title: "Session") {
                        if let size = session.sizeLabel {
                            FactRow(label: "Weight") {
                                HStack(spacing: 8) {
                                    Text(size)
                                    if let cost = session.resumeCostLabel {
                                        Text("\(cost) to resume").foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        FactRow(label: "Prompts") { Text("\(session.prompts)") }
                        FactRow(label: "Started") { Text(session.start.formatted(date: .abbreviated, time: .shortened)) }
                        FactRow(label: "Last") { Text(session.last.formatted(date: .abbreviated, time: .shortened)) }
                        FactRow(label: "ID") { Text(session.id).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                    }
                }
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyState(symbol: "sidebar.right", title: "Select a session")
        }
    }
}

// MARK: Cleanup

private let cleanupKinds = ["merged", "gone", "missing_worktree", "stale", "orphan_session"]

private func cleanupInfo(_ kind: String) -> (symbol: String, color: Color, blurb: String) {
    switch kind {
    case "merged": ("checkmark.seal", .green, "Merged into the base branch. Safe to drop the folder and local branch.")
    case "gone": ("icloud.slash", .blue, "The branch was deleted on origin, usually after the PR merged.")
    case "missing_worktree": ("folder.badge.questionmark", .purple, "The folder is gone but git still tracks it; this just prunes the record.")
    case "stale": ("hourglass", .orange, "No commits or Claude activity for a long time.")
    case "orphan_session": ("bubble.left.and.exclamationmark.bubble.right", .pink, "Claude sessions whose folder and branch no longer exist. They go to wk's trash and can be restored.")
    default: ("questionmark.circle", .gray, "")
    }
}

/// Cleanup tab: category filters, grouped suggestions with risk badges, and a summary panel that
/// says exactly what removing the selection will do.
struct CleanupPane: View {
    @Environment(AppStore.self) private var store
    @State private var selected: Set<String> = []
    @State private var force = false
    @State private var filter: String?

    var body: some View {
        let all = store.visibleCleanup
        let items = filter.map { kind in all.filter { $0.kind == kind } } ?? all
        Group {
            if store.cleanupLoading && store.cleanupItems.isEmpty {
                ProgressView("Checking branches for merged, deleted and unpushed work…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if all.isEmpty {
                EmptyState(symbol: "sparkles", title: "All clean",
                           subtitle: "Merged branches, deleted remotes, missing folders, stale tasks and orphaned sessions show up here.")
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    filterBar(all)
                    HStack(alignment: .top, spacing: 40) {
                        list(items)
                            .frame(minWidth: 460, maxWidth: 760)
                        summary(all)
                            .frame(width: 340)
                    }
                }
            }
        }
        .onChange(of: store.cleanupItems) { _, items in selected.formIntersection(items.map(\.id)) }
        .onReceive(NotificationCenter.default.publisher(for: .wkCleanupToggle)) { _ in
            if let id = store.selectedCleanupID { toggle(id) }
        }
    }

    // MARK: Filters

    private func filterBar(_ items: [CleanupItem]) -> some View {
        HStack(spacing: 8) {
            pill(title: "All", count: items.count, color: .secondary, active: filter == nil) { filter = nil }
            ForEach(cleanupKinds.filter { kind in items.contains { $0.kind == kind } }, id: \.self) { kind in
                let info = cleanupInfo(kind)
                pill(title: items.first { $0.kind == kind }?.kindLabel ?? kind, symbol: info.symbol,
                     count: items.filter { $0.kind == kind }.count, color: info.color, active: filter == kind) {
                    filter = filter == kind ? nil : kind
                }
            }
            Spacer()
            Button { store.loadCleanup() } label: {
                Label(store.cleanupLoading ? "Checking…" : "Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(store.cleanupLoading)
        }
    }

    private func pill(title: String, symbol: String? = nil, count: Int, color: Color, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).foregroundStyle(color) }
                Text(title)
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: active ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(active ? Color.white.opacity(0.12) : Color.white.opacity(0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(active ? 0.18 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: List

    private func list(_ items: [CleanupItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    let kinds = cleanupKinds.filter { kind in items.contains { $0.kind == kind } }
                    ForEach(kinds, id: \.self) { kind in
                        let group = items.filter { $0.kind == kind }
                        groupHeader(kind, group, first: kind == kinds.first)
                        ForEach(group) { item in
                            row(item)
                                .id(item.id)
                                .onTapGesture { store.selectedCleanupID = item.id; toggle(item.id) }
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .onChange(of: store.selectedCleanupID) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    private func groupHeader(_ kind: String, _ group: [CleanupItem], first: Bool) -> some View {
        let info = cleanupInfo(kind)
        let ids = Set(group.map(\.id))
        let allSelected = ids.isSubset(of: selected)
        // No icon here (the filter pills carry it): title and blurb share one flush left edge.
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text((group.first?.kindLabel ?? kind).uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(info.color)
                Text("\(group.count)").font(.system(size: 12)).foregroundStyle(.tertiary)
                Spacer()
                Button(allSelected ? "Deselect group" : "Select group") {
                    if allSelected { selected.subtract(ids) } else { selected.formUnion(ids) }
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(info.blurb).font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.top, first ? 2 : 18).padding(.bottom, 6)
    }

    private func row(_ item: CleanupItem) -> some View {
        let isOn = selected.contains(item.id)
        let focused = store.selectedCleanupID == item.id
        return HStack(spacing: 12) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.6))
            let label = store.snapshot.repos?.first { $0.path == item.repo }?.label ?? item.repoName.uppercased()
            if !item.title.hasPrefix(label + " ") {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(item.reason).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if item.safe {
                Label("Safe", systemImage: "checkmark.shield").font(.system(size: 12)).foregroundStyle(.green.opacity(0.85))
            } else {
                Label(riskText(item), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            TimeLabel(date: item.last)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(isOn ? Color.accentColor.opacity(0.16) : focused ? Color.white.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    private func riskText(_ item: CleanupItem) -> String {
        var parts: [String] = []
        if item.dirty > 0 { parts.append("\(item.dirty) uncommitted") }
        if item.unpushed > 0 { parts.append("\(item.unpushed) unpushed") }
        return parts.isEmpty ? "Check first" : parts.joined(separator: " · ")
    }

    // MARK: Summary

    private func summary(_ items: [CleanupItem]) -> some View {
        let chosen = items.filter { selected.contains($0.id) }
        let risky = chosen.filter { !$0.safe }
        let sessions = chosen.filter { $0.kind == "orphan_session" }.count
        let tasks = chosen.count - sessions
        let blocked = !risky.isEmpty && !force
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(chosen.isEmpty ? "Nothing selected" : "\(chosen.count) selected")
                    .font(.system(size: 24, weight: .semibold))
                Text("\(items.filter(\.safe).count) of \(items.count) suggestions are safe to remove.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Select all safe") { selected = Set(items.filter(\.safe).map(\.id)) }
                    .buttonStyle(.bordered)
                Button("Clear") { selected = [] }
                    .buttonStyle(.bordered)
                    .disabled(selected.isEmpty)
            }

            if !chosen.isEmpty {
                DetailCard(title: "What happens") {
                    if tasks > 0 {
                        Label("\(tasks) worktree folder\(tasks == 1 ? "" : "s") and local branch\(tasks == 1 ? "" : "es") removed, cmux workspaces closed",
                              systemImage: "trash")
                    }
                    if sessions > 0 {
                        Label("\(sessions) session\(sessions == 1 ? "" : "s") moved to wk's trash (restorable)", systemImage: "arrow.uturn.backward.circle")
                    }
                    Label("Remote branches on origin are kept", systemImage: "cloud")
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }

            if !risky.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(risky.count) selected item\(risky.count == 1 ? " has" : "s have") work that would be lost",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.system(size: 13, weight: .medium))
                    Toggle("Remove them anyway (uncommitted and unpushed work is lost)", isOn: $force)
                        .toggleStyle(.checkbox).font(.system(size: 12))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    store.applyCleanup(ids: Array(selected), force: force)
                    selected = []
                    force = false
                } label: {
                    Label(chosen.isEmpty ? "Remove" : "Remove \(chosen.count)", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.82, green: 0.22, blue: 0.2))
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(chosen.isEmpty || blocked)
                Text(blocked ? "Tick “Remove them anyway” or deselect the orange items."
                             : chosen.isEmpty ? "Select items on the left." : "⌘↵")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

extension Notification.Name {
    static let wkCleanupToggle = Notification.Name("wkCleanupToggle")
}
