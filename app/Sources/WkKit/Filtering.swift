import Foundation

public enum TaskFilter {
    /// Tasks for the list: folded env branches and hidden tasks are excluded unless asked.
    /// Every search word must match the repo, branch, ticket, note or a session title.
    public static func tasks(_ tasks: [WkTask], query: String, includeHidden: Bool = false, repo: String? = nil) -> [WkTask] {
        let terms = searchTerms(query)
        let visible = tasks.filter { task in
            if task.isFolded { return false }
            if task.hidden && !includeHidden { return false }
            if let repo, task.repo != repo { return false }
            return matches(haystack(for: task), terms)
        }
        guard let ticketNumber = terms.first, terms.count == 1, ticketNumber.allSatisfy(\.isNumber) else { return visible }
        // "5346" puts the exact ticket first.
        return visible.sorted { left, right in
            let leftExact = left.ticket?.hasSuffix("-" + ticketNumber) == true
            let rightExact = right.ticket?.hasSuffix("-" + ticketNumber) == true
            return leftExact && !rightExact
        }
    }

    public static func sessions(_ sessions: [Session], query: String) -> [Session] {
        let terms = searchTerms(query)
        return sessions.filter { session in
            matches([session.id, session.displayTitle, session.firstPrompt ?? "", session.cwd, (session.branches ?? []).joined(separator: " ")]
                .joined(separator: " ").lowercased(), terms)
        }
    }

    public static func cleanup(_ items: [CleanupItem], query: String) -> [CleanupItem] {
        let terms = searchTerms(query)
        return items.filter { matches([$0.title, $0.repoName, $0.branch ?? "", $0.reason, $0.kindLabel].joined(separator: " ").lowercased(), terms) }
    }

    static func haystack(for task: WkTask) -> String {
        var parts = [task.repoLabel, task.repoName, task.branch, task.ticket ?? "", task.note ?? "", task.issue?.summary ?? ""]
        parts += task.sessions.map(\.displayTitle)
        parts += task.envBranches ?? []
        return parts.joined(separator: " ").lowercased()
    }

    static func searchTerms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func matches(_ haystack: String, _ terms: [String]) -> Bool {
        terms.allSatisfy { haystack.contains($0) }
    }
}

public struct MenuBarStatus: Equatable, Sendable {
    public let symbol: String
    public let badge: String

    /// Badge = sessions waiting for you; symbol shows whether any Claude is working.
    public init(counts: Counts, cmuxRunning: Bool) {
        if counts.waiting > 0 {
            symbol = "bell.badge.fill"
        } else if counts.running > 0 {
            symbol = "circle.dotted.circle"
        } else {
            symbol = "square.stack.3d.up"
        }
        badge = counts.waiting > 0 ? "\(counts.waiting)" : ""
    }
}

public enum StateChanges {
    /// Sessions that were running and are now waiting for the user (Claude finished its turn).
    public static func finished(previous: [Session], current: [Session]) -> [Session] {
        let before = Dictionary(previous.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        return current.filter { session in
            session.state == .waiting && before[session.id] == .running
        }
    }
}

/// A pull request change worth a notification.
public struct PRAlert: Hashable, Sendable {
    public enum Kind: Sendable { case checksFailing, changesRequested, merged }
    public var taskID: String
    public var title: String // "CUSTOMER ABC-4534 · dev #860"
    public var kind: Kind
    public var pr: PullRequest

    public var headline: String {
        switch kind {
        case .checksFailing: "Checks failing on PR #\(pr.number)"
        case .changesRequested: "Changes requested on PR #\(pr.number)"
        case .merged: "PR #\(pr.number) merged"
        }
    }
}

extension StateChanges {
    /// Compares each task's PRs (main and -dev/-stg) with the previous snapshot. A PR seen for the first
    /// time never alerts, so starting wk doesn't flood you.
    public static func prAlerts(previous: [WkTask], current: [WkTask]) -> [PRAlert] {
        func prs(_ task: WkTask) -> [(String, PullRequest)] {
            (task.pr.map { [("", $0)] } ?? []) + (task.envPrs ?? []).map { ($0.env + " ", $0.pr) }
        }
        var before: [String: PullRequest] = [:]
        for task in previous {
            for (_, pr) in prs(task) { before[pr.url] = pr }
        }
        var alerts: [PRAlert] = []
        for task in current where task.parentId == nil || task.parentId?.isEmpty == true {
            for (env, pr) in prs(task) {
                guard let old = before[pr.url] else { continue }
                let title = "\(task.displayName) · \(env)#\(pr.number)"
                if pr.state == "merged" && old.state != "merged" {
                    alerts.append(PRAlert(taskID: task.id, title: title, kind: .merged, pr: pr))
                } else if pr.isLive && pr.checks == "failing" && old.checks != "failing" {
                    alerts.append(PRAlert(taskID: task.id, title: title, kind: .checksFailing, pr: pr))
                } else if pr.isLive && pr.review == "changes_requested" && old.review != "changes_requested" {
                    alerts.append(PRAlert(taskID: task.id, title: title, kind: .changesRequested, pr: pr))
                }
            }
        }
        return alerts
    }
}

public enum RelativeTime {
    public static func short(_ date: Date, now: Date = Date()) -> String {
        guard date > .distantPast.addingTimeInterval(1) else { return "–" }
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        case ..<(86400 * 60): return "\(Int(seconds / 86400))d"
        default: return "\(Int(seconds / 86400 / 30))mo"
        }
    }
}

public enum PathDisplay {
    public static func collapse(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    public static func expand(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
    }

    /// The config file wk reads (WK_CONFIG overrides it, as in demo mode).
    public static var configFile: String {
        ProcessInfo.processInfo.environment["WK_CONFIG"] ?? expand("~/.config/wk/config.toml")
    }
}
