import XCTest
@testable import WkKit

final class DecodingTests: XCTestCase {
    /// Shape produced by `wk serve` (Go encoding/json): snake_case, RFC 3339 nano dates, nulls for empty slices.
    static let snapshotJSON = """
    {"generated_at":"2026-11-11T16:45:34.123456789+06:00","cmux_running":true,
     "repos":[{"path":"/r/frontend/admin","name":"frontend/admin","label":"ADMIN","base_branch":"production",
               "worktrees":[{"path":"/r/frontend/admin","branch":"ABC-1-x","head":"abc","main":true,"missing":false,"locked":false,"detached":false}]}],
     "tasks":[{"id":"~/r/frontend/admin#ABC-1-x","repo":"/r/frontend/admin","repo_name":"frontend/admin","repo_label":"ADMIN",
               "branch":"ABC-1-x","ticket":"ABC-1","path":"/r/frontend/admin","main_worktree":true,"detached":false,"missing":false,
               "is_base":false,"commit_date":"2026-11-10T10:00:00Z","subject":"feat","gone":false,"merged":false,"ahead":1,"behind":0,
               "dirty":2,"workspace":{"id":"W","ref":"workspace:1","title":"ADMIN","ports":[3000],"selected":true},
               "sessions":[{"id":"s1","title":"passport toggle","cwd":"/r/frontend/admin","branch":"ABC-1-x","branches":null,
                            "start":"2026-11-10T10:00:00Z","last":"2026-11-11T10:00:00.5Z","prompts":3,"state":"waiting",
                            "cwd_exists":true,"primary":true,"task_id":"~/r/frontend/admin#ABC-1-x"}],
               "pinned":false,"hidden":false,"last_activity":"2026-11-11T10:00:00Z","running":0,"waiting":1,
               "env_branches":["ABC-1-dev"]},
              {"id":"~/r/frontend/admin#ABC-1-dev","repo":"/r/frontend/admin","repo_name":"frontend/admin","repo_label":"ADMIN",
               "branch":"ABC-1-dev","main_worktree":false,"detached":false,"missing":false,"is_base":false,
               "commit_date":"0001-01-01T00:00:00Z","gone":false,"merged":false,"ahead":0,"behind":0,"dirty":0,"sessions":[],
               "pinned":false,"hidden":false,"last_activity":"0001-01-01T00:00:00Z","running":0,"waiting":0,
               "parent_id":"~/r/frontend/admin#ABC-1-x"}],
     "sessions":null,"counts":{"running":0,"waiting":1,"open":1,"tasks":1}}
    """

    func testDecodesGoSnapshot() throws {
        let snapshot = try JSON.decoder.decode(Snapshot.self, from: Data(Self.snapshotJSON.utf8))
        let task = try XCTUnwrap(snapshot.tasks?.first)
        XCTAssertEqual(task.repoLabel, "ADMIN")
        XCTAssertEqual(task.workspace?.ports, [3000])
        XCTAssertEqual(task.sessions.first?.state, .waiting)
        XCTAssertEqual(task.envBranches, ["ABC-1-dev"])
        XCTAssertTrue(snapshot.tasks?[1].isFolded ?? false)
        XCTAssertEqual(snapshot.tasks?[1].commitDate, .distantPast)
        XCTAssertNil(snapshot.sessions)
    }

    func testParsesNanosecondDates() throws {
        let date = try XCTUnwrap(JSON.parseDate("2026-11-11T16:45:34.123456789+06:00"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_794_393_934.123, accuracy: 0.001)
    }

    func testRepoSettingsKeysArePathsAndStayUntouched() throws {
        let config = WkConfig(roots: ["~/code"], baseBranch: "production", recentDays: 30, claudeDir: "~/.claude", labelStripPrefixes: ["acme-"],
                              repos: ["~/code/backend/api": RepoSettings(serverCmd: "make run", postWorktree: ["yarn"])])
        let data = try JSON.encoder.encode(config)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("backend\\/api"), text)
        XCTAssertTrue(text.contains("\"server_cmd\""), text)
        XCTAssertTrue(text.contains("\"base_branch\""), text)
        XCTAssertTrue(text.contains("\"label_strip_prefixes\""), text)
        let decoded = try JSON.decoder.decode(WkConfig.self, from: data)
        XCTAssertEqual(decoded.repos?["~/code/backend/api"]?.serverCmd, "make run")
    }

    func testRemovePlanOptionKeysStaySnakeCase() throws {
        let json = """
        {"task":\(Self.taskJSON),"facts":{"dirty":0,"unpushed":2,"has_remote":true,"merged":false,"sessions":1,"live_sessions":0,"main_worktree":false},
         "options":{"remove_worktree":{"available":true,"default":true},"delete_remote":{"available":true,"default":false,"reason":"x"}},
         "requires_confirm":true}
        """
        let plan = try JSON.decoder.decode(RemovePlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.options[RemoveOptionKey.removeWorktree.rawValue]?.default, true)
        XCTAssertEqual(plan.options[RemoveOptionKey.deleteRemote.rawValue]?.reason, "x")
        XCTAssertTrue(plan.requiresConfirm)
    }

    static let taskJSON = """
    {"id":"t","repo":"/r","repo_name":"r","repo_label":"R","branch":"b","main_worktree":false,"detached":false,"missing":false,
     "is_base":false,"commit_date":"2026-01-01T00:00:00Z","gone":false,"merged":false,"ahead":0,"behind":0,"dirty":0,
     "sessions":[],"pinned":false,"hidden":false,"last_activity":"2026-01-01T00:00:00Z","running":0,"waiting":0}
    """
}

final class FilterTests: XCTestCase {
    private func snapshot() throws -> Snapshot {
        try JSON.decoder.decode(Snapshot.self, from: Data(DecodingTests.snapshotJSON.utf8))
    }

    func testHidesFoldedEnvBranchesButSearchesTheirNames() throws {
        let tasks = try snapshot().tasks ?? []
        XCTAssertEqual(TaskFilter.tasks(tasks, query: "").map(\.branch), ["ABC-1-x"])
        XCTAssertEqual(TaskFilter.tasks(tasks, query: "dev").map(\.branch), ["ABC-1-x"], "env branch names find the feature")
    }

    func testMatchesSessionTitlesAndRequiresEveryWord() throws {
        let tasks = try snapshot().tasks ?? []
        XCTAssertEqual(TaskFilter.tasks(tasks, query: "passport admin").count, 1)
        XCTAssertEqual(TaskFilter.tasks(tasks, query: "passport widget").count, 0)
    }

    func testMenuBarBadgeCountsWaitingSessions() {
        let status = MenuBarStatus(counts: Counts(running: 2, waiting: 3, open: 1, tasks: 9), cmuxRunning: true)
        XCTAssertEqual(status.badge, "3")
        XCTAssertEqual(MenuBarStatus(counts: Counts(running: 1, waiting: 0, open: 0, tasks: 1), cmuxRunning: true).badge, "")
    }

    func testDetectsSessionsThatFinishedTheirTurn() throws {
        var running = try XCTUnwrap(try snapshot().tasks?.first?.sessions.first)
        running.state = .running
        var waiting = running
        waiting.state = .waiting
        XCTAssertEqual(StateChanges.finished(previous: [running], current: [waiting]).map(\.id), ["s1"])
        XCTAssertTrue(StateChanges.finished(previous: [waiting], current: [waiting]).isEmpty, "no repeat notifications")
    }

    func testClassifiesFileEventsIntoScopes() {
        let claude = "/Users/me/.claude/projects", cmux = "/Users/me/.cmuxterm"
        XCTAssertEqual(ChangeClassifier.scope(for: claude + "/-x/a.jsonl", claudeProjects: claude, cmuxState: cmux), .sessions)
        XCTAssertEqual(ChangeClassifier.scope(for: cmux + "/claude-hook-sessions.json", claudeProjects: claude, cmuxState: cmux), .sessions)
        XCTAssertEqual(ChangeClassifier.scope(for: cmux + "/events.jsonl", claudeProjects: claude, cmuxState: cmux), [.cmux, .sessions])
        XCTAssertEqual(ChangeClassifier.scope(for: "/r/admin/.git/HEAD", claudeProjects: claude, cmuxState: cmux), .git)
        XCTAssertEqual(ChangeClassifier.scope(for: "/r/admin/.git/index", claudeProjects: claude, cmuxState: cmux), [])
        XCTAssertEqual(ChangeClassifier.scope(for: "/r/admin/.git/objects/ab/cd", claudeProjects: claude, cmuxState: cmux), [])
    }

    func testRelativeTime() {
        let now = Date()
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-30), now: now), "now")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(RelativeTime.short(.distantPast, now: now), "–")
    }
}

final class UpdatesTests: XCTestCase {
    func testComparesDottedVersionsNumerically() {
        XCTAssertTrue(Updates.isNewer("0.2.10", than: "0.2.9"))
        XCTAssertTrue(Updates.isNewer("0.3", than: "0.2.9"))
        XCTAssertFalse(Updates.isNewer("0.2.5", than: "0.2.5"))
        XCTAssertFalse(Updates.isNewer("0.2.4", than: "0.2.5"))
    }
}

final class LayoutTests: XCTestCase {
    func testFramesMirrorTheCoreArrangements() {
        let panes = [PaneConfig(kind: "claude"), PaneConfig(kind: "server"), PaneConfig(kind: "shell", name: "Git")]
        let standard = LayoutConfig(arrange: "main-left", mainSize: 60, panes: panes).frames()
        XCTAssertEqual(standard[0], CGRect(x: 0, y: 0, width: 0.6, height: 1))
        XCTAssertEqual(standard[1].minX, 0.6, accuracy: 0.001)
        XCTAssertEqual(standard[2].minY, 0.5, accuracy: 0.001)
        XCTAssertEqual(LayoutConfig(arrange: "columns", panes: panes).frames().map(\.width), [1.0 / 3, 1.0 / 3, 1.0 / 3])
        XCTAssertEqual(LayoutConfig(arrange: "grid", panes: panes).frames().filter { $0.minX == 0 }.count, 2)
    }

    func testLayoutRoundTripsThroughSnakeCase() throws {
        let layout = LayoutConfig(arrange: "tabs", mainSize: 55, panes: [PaneConfig(kind: "command", name: "Git", command: "lazygit")])
        let data = try JSON.encoder.encode(layout)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"main_size\":55"))
        XCTAssertEqual(try JSON.decoder.decode(LayoutConfig.self, from: data), layout)
    }
}
