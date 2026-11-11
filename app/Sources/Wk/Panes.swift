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
                .frame(minWidth: 380, idealWidth: 480, maxWidth: 520)
                Spacer().frame(width: 40)
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
                            Text(task.repoLabel).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
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
                                ForEach(changes.prefix(8), id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).lineLimit(1) }
                                if changes.count > 8 { Text("… \(changes.count - 8) more").font(.system(size: 12)).foregroundStyle(.secondary) }
                            }
                        }
                        if let log = detail.log, !log.isEmpty {
                            DetailSection(title: "Commits") {
                                ForEach(log, id: \.self) { Text($0).font(.system(size: 12)).lineLimit(1).foregroundStyle(.secondary) }
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
            .font(.system(size: 13))
        }
    }

    private func sessions(_ task: WkTask) -> some View {
        DetailSection(title: "Claude sessions (\(task.sessions.count))") {
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

// MARK: Sessions

struct SessionsPane: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Toggle("Include trash", isOn: $store.includeTrash)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
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
            .frame(minWidth: 380, idealWidth: 480, maxWidth: 520)
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
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SessionStateIcon(session: session)
                        Text(session.state.rawValue.capitalized).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
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
                            GridRow { Text("ID").foregroundStyle(.secondary); Text(session.id).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                        }
                        .font(.system(size: 13))
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

private let cleanupKinds = ["merged", "gone", "missing_worktree", "stale", "orphan_session"]

private func cleanupInfo(_ kind: String) -> (symbol: String, color: Color, blurb: String) {
    switch kind {
    case "merged": ("checkmark.seal", .green, "Merged into the base branch. Safe to drop the folder and local branch.")
    case "gone": ("cloud.slash", .blue, "The branch was deleted on origin, usually after the PR merged.")
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
                    ForEach(cleanupKinds.filter { kind in items.contains { $0.kind == kind } }, id: \.self) { kind in
                        let group = items.filter { $0.kind == kind }
                        groupHeader(kind, group)
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

    private func groupHeader(_ kind: String, _ group: [CleanupItem]) -> some View {
        let info = cleanupInfo(kind)
        let ids = Set(group.map(\.id))
        let allSelected = ids.isSubset(of: selected)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label((group.first?.kindLabel ?? kind).uppercased(), systemImage: info.symbol)
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
        .padding(.top, 18).padding(.bottom, 6)
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
            Text(RelativeTime.short(item.last))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
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
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(chosen.isEmpty ? "Nothing selected" : "\(chosen.count) selected")
                    .font(.system(size: 26, weight: .semibold))
                Text("\(items.filter(\.safe).count) of \(items.count) suggestions are safe to remove.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Select all safe") { selected = Set(items.filter(\.safe).map(\.id)) }
                Button("Clear") { selected = [] }.disabled(selected.isEmpty)
            }
            .controlSize(.large)

            if !chosen.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WHAT HAPPENS").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    if tasks > 0 {
                        Label("\(tasks) worktree folder\(tasks == 1 ? "" : "s") and local branch\(tasks == 1 ? "" : "es") removed, cmux workspaces closed",
                              systemImage: "trash")
                    }
                    if sessions > 0 {
                        Label("\(sessions) session\(sessions == 1 ? "" : "s") moved to wk's trash (restorable)", systemImage: "arrow.uturn.backward.circle")
                    }
                    Label("Remote branches on origin are kept", systemImage: "cloud")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if !risky.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(risky.count) selected item\(risky.count == 1 ? " has" : "s have") work that would be lost",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout.weight(.medium))
                    Toggle("Remove them anyway (uncommitted and unpushed work is lost)", isOn: $force)
                        .toggleStyle(.checkbox).font(.system(size: 12))
                }
                .padding(12)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            }

            Button(role: .destructive) {
                store.applyCleanup(ids: Array(selected), force: force)
                selected = []
                force = false
            } label: {
                Text(chosen.isEmpty ? "Remove" : "Remove \(chosen.count)")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(chosen.isEmpty || blocked)
            if blocked {
                Text("Tick “Remove them anyway” or deselect the items marked in orange.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
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
