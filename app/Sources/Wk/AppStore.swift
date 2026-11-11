import AppKit
import Observation
import WkKit

enum PaletteTab: Int, CaseIterable, Identifiable {
    case tasks = 1, sessions, cleanup, settings
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .sessions: "Sessions"
        case .cleanup: "Cleanup"
        case .settings: "Settings"
        }
    }
}

/// A modal layer inside the palette (overlays instead of sheets, so the floating panel keeps focus).
enum Overlay: Equatable {
    case actions(taskID: String)
    case sessionActions(sessionID: String)
    case newTask(NewTaskSeed)
    case remove(taskID: String)
    case checkout(taskID: String, mode: String, session: String?, single: Bool)
    case prompt(PromptKind)
    case pickSession(taskID: String)
}

struct NewTaskSeed: Equatable {
    var repo: String?
    var from: String = "base"
    var ref: String?
}

enum PromptKind: Equatable {
    case renameBranch(taskID: String, current: String)
    case note(taskID: String, current: String)
    case renameSession(sessionID: String, current: String)
    case switchBranch(taskID: String, repo: String)
    case worktreeForBranch(repo: String)
}

struct Activity: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var lines: [String] = []
    var done = false
    var failed = false
}

@MainActor
@Observable
final class AppStore {
    var snapshot: Snapshot = .empty
    var sessions: [Session] = []
    var cleanupItems: [CleanupItem] = []
    var cleanupLoading = false
    var config: WkConfig?
    var detail: TaskDetail?

    var tab: PaletteTab = .tasks
    var query = ""
    var selectedTaskID: String?
    var selectedSessionID: String?
    var selectedCleanupID: String?
    var overlay: Overlay?
    var includeTrash = false
    var toast: String?
    var activities: [Activity] = []
    var coreMissing = false
    var lastError: String?

    var notifyWhenWaiting: Bool {
        didSet { UserDefaults.standard.set(notifyWhenWaiting, forKey: "notifyWhenWaiting") }
    }
    /// How dark the full-screen backdrop is (0 = no tint).
    var backdropOpacity: Double {
        didSet { UserDefaults.standard.set(backdropOpacity, forKey: "backdropOpacity") }
    }
    /// Blur the desktop behind the palette, like Spotlight.
    var blurBackdrop: Bool {
        didSet { UserDefaults.standard.set(blurBackdrop, forKey: "blurBackdrop") }
    }

    @ObservationIgnored private let client: CoreClient?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var watchedRepos: [String] = []
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var pendingScope: ChangeScope = []
    @ObservationIgnored private var lastCmuxRefresh = Date.distantPast
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var sessionSearch: Task<Void, Never>?
    @ObservationIgnored var onPaletteRequest: ((Overlay?) -> Void)?

    init() {
        notifyWhenWaiting = UserDefaults.standard.object(forKey: "notifyWhenWaiting") as? Bool ?? false
        backdropOpacity = UserDefaults.standard.object(forKey: "backdropOpacity") as? Double ?? 0.35
        blurBackdrop = UserDefaults.standard.object(forKey: "blurBackdrop") as? Bool ?? true
        if let executable = CoreClient.locateExecutable() {
            client = CoreClient(executable: executable)
        } else {
            client = nil
            coreMissing = true
        }
    }

    // MARK: Derived

    var visibleTasks: [WkTask] { TaskFilter.tasks(snapshot.tasks ?? [], query: query) }
    var visibleCleanup: [CleanupItem] { TaskFilter.cleanup(cleanupItems, query: query) }
    var status: MenuBarStatus { MenuBarStatus(counts: snapshot.counts, cmuxRunning: snapshot.cmuxRunning) }

    var selectedTask: WkTask? {
        guard let id = selectedTaskID else { return visibleTasks.first }
        return (snapshot.tasks ?? []).first { $0.id == id } ?? visibleTasks.first
    }

    var selectedSession: Session? {
        guard let id = selectedSessionID else { return sessions.first }
        return sessions.first { $0.id == id } ?? sessions.first
    }

    func task(_ id: String) -> WkTask? { (snapshot.tasks ?? []).first { $0.id == id } }

    func session(_ id: String) -> Session? {
        sessions.first { $0.id == id } ?? (snapshot.sessions ?? []).first { $0.id == id }
            ?? (snapshot.tasks ?? []).lazy.flatMap(\.sessions).first { $0.id == id }
    }

    // MARK: Lifecycle

    func start() {
        refresh(.all)
        loadConfig()
    }

    /// Coalesces change bursts: one request in flight, pending scopes merged; cmux at most every 2s.
    func refresh(_ scope: ChangeScope) {
        guard client != nil, !scope.isEmpty else { return }
        pendingScope.formUnion(scope)
        guard !refreshing else { return }
        refreshing = true
        Task { await drainRefresh() }
    }

    private func drainRefresh() async {
        while !pendingScope.isEmpty {
            var scope = pendingScope
            pendingScope = []
            if scope.contains(.cmux) && scope != .all && Date().timeIntervalSince(lastCmuxRefresh) < 2 {
                scope.remove(.cmux)
                scheduleDeferredCmux()
            }
            if scope.contains(.cmux) { lastCmuxRefresh = Date() }
            await loadSnapshot(scope)
        }
        refreshing = false
    }

    private var deferredCmux = false
    private func scheduleDeferredCmux() {
        guard !deferredCmux else { return }
        deferredCmux = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            deferredCmux = false
            refresh(.cmux)
        }
    }

    private struct ScopeArgs: Encodable {
        var git: Bool
        var cmux: Bool
    }

    private func loadSnapshot(_ scope: ChangeScope) async {
        guard let client else { return }
        do {
            let previous = snapshot.tasks?.flatMap(\.sessions) ?? []
            let next = try await client.call("snapshot", ScopeArgs(git: scope.contains(.git), cmux: scope.contains(.cmux)), as: Snapshot.self)
            snapshot = next
            lastError = nil
            if notifyWhenWaiting {
                let finished = StateChanges.finished(previous: previous, current: next.tasks?.flatMap(\.sessions) ?? [])
                for session in Set(finished) {
                    Notifier.claudeWaiting(session: session, task: task(session.taskId ?? ""))
                }
            }
            updateWatcher()
            if tab == .sessions { searchSessions() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func updateWatcher() {
        let repos = (snapshot.repos ?? []).map(\.path).sorted()
        guard repos != watchedRepos else { return }
        watchedRepos = repos
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let claudeProjects = (config?.claudeDir.replacingOccurrences(of: "~", with: home) ?? home + "/.claude") + "/projects"
        let cmuxState = home + "/.cmuxterm"
        if watcher == nil {
            watcher = FileWatcher { [weak self] paths in
                var scope: ChangeScope = []
                for path in paths {
                    scope.formUnion(ChangeClassifier.scope(for: path, claudeProjects: claudeProjects, cmuxState: cmuxState))
                }
                guard !scope.isEmpty else { return }
                Task { @MainActor in self?.refresh(scope) }
            }
        }
        watcher?.watch([claudeProjects, cmuxState] + repos.map { $0 + "/.git" })
    }

    // MARK: Selection side effects

    func selectionChanged() {
        detailTask?.cancel()
        guard let task = selectedTask, let client else { detail = nil; return }
        if detail?.task.id != task.id { detail = nil }
        detailTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            if let loaded = try? await client.call("show", ["task": task.id], as: TaskDetail.self), !Task.isCancelled {
                detail = loaded
            }
        }
    }

    func searchSessions() {
        sessionSearch?.cancel()
        guard let client else { return }
        let query = query, includeTrash = includeTrash
        sessionSearch = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            struct Args: Encodable { var query: String; var trash: Bool }
            if let found = try? await client.call("sessions", Args(query: query, trash: includeTrash), as: [Session]?.self), !Task.isCancelled {
                sessions = found ?? []
            }
        }
    }

    func loadCleanup() {
        guard let client, !cleanupLoading else { return }
        cleanupLoading = true
        Task {
            defer { cleanupLoading = false }
            do {
                cleanupItems = try await client.call("cleanup", as: [CleanupItem]?.self) ?? []
            } catch {
                show(error)
            }
        }
    }

    func loadConfig() {
        guard let client else { return }
        Task { config = try? await client.call("config_get", as: WkConfig.self) }
    }

    // MARK: Actions

    struct OpenArgs: Encodable {
        var task: String
        var session: String?
        var mode: String?
        var via: String?
        var stash: Bool?
        var newWorkspace: Bool?
        var single: Bool?
    }

    /// `single` gives a newly created cmux workspace one Claude pane instead of the 3-pane layout.
    func open(_ task: WkTask, mode: String = "resume", session: String? = nil, via: String? = nil, newWorkspace: Bool = false, single: Bool = false) {
        if !task.hasFolder && via == nil && !task.detached {
            overlay = .checkout(taskID: task.id, mode: mode, session: session, single: single)
            return
        }
        run("Opening \(task.displayName)", hidePalette: true) { client, progress in
            let result = try await client.call("open", OpenArgs(task: task.id, session: session, mode: mode, via: via, newWorkspace: newWorkspace, single: single),
                                               as: OpenResult.self, progress: progress)
            return Self.describe(result)
        }
    }

    func resume(_ session: Session, newWorkspace: Bool = false, recreate: Bool = false, single: Bool = false) {
        struct Args: Encodable { var session: String; var newWorkspace: Bool; var recreate: Bool; var single: Bool }
        run("Resuming \(session.displayTitle)", hidePalette: true) { client, progress in
            let result = try await client.call("resume", Args(session: session.id, newWorkspace: newWorkspace, recreate: recreate, single: single),
                                               as: OpenResult.self, progress: progress)
            return Self.describe(result)
        }
    }

    struct NewTaskArgs: Encodable {
        var repo: String
        var name: String
        var from: String
        var ref: String?
        var mode: String
        var stash: Bool
        var setup: Bool
        var open: String?
    }

    func createTask(_ args: NewTaskArgs) {
        overlay = nil
        run("Creating \(args.name)", hidePalette: true, notify: true) { client, progress in
            let result = try await client.call("new", args, as: NewTaskResult.self, progress: progress)
            return "Created \(result.branch) at \(PathDisplay.collapse(result.path))"
        }
    }

    func applyRemove(taskID: String, options: [String: Bool], confirm: String) {
        struct Args: Encodable { var task: String; var options: [String: Bool]; var confirm: String }
        overlay = nil
        run("Removing", notify: true) { client, progress in
            let steps = try await client.call("remove", Args(task: taskID, options: options, confirm: confirm), as: [StepResult]?.self, progress: progress) ?? []
            let failed = steps.filter { !$0.ok }
            if !failed.isEmpty { throw CoreError(message: failed.map { "\($0.step): \($0.message)" }.joined(separator: "\n")) }
            return steps.map(\.message).joined(separator: " · ")
        }
    }

    func applyCleanup(ids: [String], force: Bool) {
        struct Args: Encodable { var ids: [String]; var force: Bool }
        run("Cleaning up \(ids.count) item(s)", notify: true) { client, progress in
            let steps = try await client.call("cleanup_apply", Args(ids: ids, force: force), as: [StepResult]?.self, progress: progress) ?? []
            let failed = steps.filter { !$0.ok }.count
            return failed == 0 ? "Cleaned up \(ids.count) item(s)" : "\(steps.count - failed) done, \(failed) skipped or failed"
        } after: { [weak self] in
            self?.loadCleanup()
        }
    }

    func taskCommand(_ command: String, _ args: [String: String], title: String) {
        run(title) { client, progress in
            try await client.call(command, args, as: Message.self, progress: progress).message
        }
    }

    func setFlag(_ command: String, task: WkTask, value: Bool) {
        struct Args: Encodable { var task: String; var value: Bool }
        run(command == "pin" ? (value ? "Pinned" : "Unpinned") : (value ? "Hidden" : "Shown")) { client, _ in
            try await client.call(command, Args(task: task.id, value: value), as: Message.self).message
        }
    }

    func trash(_ session: Session) {
        taskCommand(session.trashed == true ? "restore" : "trash", ["session": session.id], title: session.trashed == true ? "Restoring" : "Trashing")
    }

    func saveConfig(_ config: WkConfig) {
        run("Saving settings") { client, _ in
            let saved = try await client.call("config_put", config, as: WkConfig.self)
            await MainActor.run { self.config = saved }
            return "Settings saved"
        }
    }

    /// Saves settings without an activity entry or toast (Settings autosaves while you edit).
    func saveConfigQuietly(_ config: WkConfig) async -> Bool {
        guard let client else { coreMissing = true; return false }
        do {
            self.config = try await client.call("config_put", config, as: WkConfig.self)
            return true
        } catch {
            show(error)
            return false
        }
    }

    func planRemove(_ taskID: String) async throws -> RemovePlan {
        guard let client else { throw CoreError(message: "wk core not found") }
        return try await client.call("remove_plan", ["task": taskID], as: RemovePlan.self)
    }

    func repoRefs(_ repo: String) async throws -> RepoRefs {
        guard let client else { throw CoreError(message: "wk core not found") }
        return try await client.call("repo_refs", ["repo": repo], as: RepoRefs.self)
    }

    /// Runs an action in the background: progress goes to the activity list; a toast (and optional
    /// notification when the palette is closed) reports the outcome; data refreshes afterwards.
    func run(_ title: String, hidePalette: Bool = false, notify: Bool = false,
             _ body: @escaping @Sendable (CoreClient, @escaping @Sendable (ProgressEvent) -> Void) async throws -> String,
             after: (@MainActor () -> Void)? = nil) {
        guard let client else { coreMissing = true; return }
        let activity = Activity(title: title)
        activities.insert(activity, at: 0)
        activities = Array(activities.prefix(20))
        let id = activity.id
        if hidePalette { PaletteController.shared.hide() }
        Task {
            do {
                let message = try await body(client) { event in
                    Task { @MainActor in self.appendLine(id, (event.isWarning ? "⚠︎ " : "") + event.message) }
                }
                finish(id, message: message, failed: false, notify: notify)
            } catch {
                finish(id, message: error.localizedDescription, failed: true, notify: true)
            }
            after?()
            refresh(.all)
        }
    }

    private func appendLine(_ id: UUID, _ line: String) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        activities[index].lines.append(line)
    }

    private func finish(_ id: UUID, message: String, failed: Bool, notify: Bool) {
        if let index = activities.firstIndex(where: { $0.id == id }) {
            activities[index].lines.append(message)
            activities[index].done = true
            activities[index].failed = failed
        }
        toast = (failed ? "⚠︎ " : "✓ ") + message
        let shownToast = toast
        Task {
            try? await Task.sleep(for: .seconds(failed ? 8 : 4))
            if toast == shownToast { toast = nil }
        }
        if notify && !PaletteController.shared.isVisible {
            Notifier.result(title: failed ? "Wk: failed" : "Wk", body: message)
        }
    }

    func show(_ error: Error) {
        toast = "⚠︎ " + error.localizedDescription
    }

    nonisolated static func describe(_ result: OpenResult) -> String {
        if result.action == "printed", let command = result.command {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            return "cmux isn't running — command copied to clipboard"
        }
        return result.message
    }

    // MARK: Small helpers

    func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast = "✓ Copied \(label)"
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
