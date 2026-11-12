import CoreGraphics
import Foundation

// Mirrors of the JSON produced by the Go core (`wk serve`). Keys are snake_case.

public enum SessionState: String, Codable, Sendable {
    case running, waiting, idle, orphan
}

public struct Worktree: Codable, Hashable, Sendable {
    public var path: String
    public var branch: String
    public var main: Bool
    public var missing: Bool
    public var detached: Bool
}

public struct Repo: Codable, Hashable, Identifiable, Sendable {
    public var path: String
    public var name: String
    public var label: String
    public var baseBranch: String
    public var serverCmd: String?
    public var worktrees: [Worktree]?
    public var error: String?
    public var id: String { path }
}

public struct Session: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var alias: String?
    public var firstPrompt: String?
    public var cwd: String
    public var branch: String
    public var branches: [String]?
    public var repo: String?
    public var taskId: String?
    public var start: Date
    public var last: Date
    public var prompts: Int
    public var state: SessionState
    public var workspace: String?
    public var surface: String?
    public var cwdExists: Bool
    public var trashed: Bool?
    public var primary: Bool?
    public var size: Int64?

    public var displayTitle: String { (alias?.isEmpty == false ? alias : nil) ?? title }
    public var isLive: Bool { state == .running || state == .waiting }

    /// Transcript size on disk, e.g. "1.8 MB". The index already has it, so showing it is free.
    public var sizeLabel: String? {
        guard let size, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Short form for list rows, e.g. "≈ 443k tokens".
    public var resumeCostCompact: String? {
        guard let size, size > 0 else { return nil }
        let tokens = size / 4
        switch tokens {
        case ..<1_000: return "≈ \(tokens) tokens"
        case ..<1_000_000: return "≈ \(tokens / 1_000)k tokens"
        default: return String(format: "≈ %.1fM tokens", Double(tokens) / 1_000_000)
        }
    }

    /// Rough cost of resuming: the whole transcript is re-read, ≈ 4 bytes per token.
    public var resumeCostLabel: String? {
        guard let size, size > 0 else { return nil }
        let tokens = size / 4
        switch tokens {
        case ..<1_000: return "≈ \(tokens) tokens"
        case ..<1_000_000: return "≈ \(tokens / 1_000)k tokens"
        default: return String(format: "≈ %.1fM tokens", Double(tokens) / 1_000_000)
        }
    }
}

public struct Workspace: Codable, Hashable, Sendable {
    public var id: String
    public var ref: String
    public var title: String
    public var ports: [Int]?
    public var selected: Bool
}

public struct WkTask: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var repo: String
    public var repoName: String
    public var repoLabel: String
    public var branch: String
    public var ticket: String?
    public var path: String?
    public var mainWorktree: Bool
    public var detached: Bool
    public var missing: Bool
    public var isBase: Bool
    public var commitDate: Date
    public var subject: String?
    public var upstream: String?
    public var gone: Bool
    public var merged: Bool
    public var ahead: Int
    public var behind: Int
    public var dirty: Int
    public var workspace: Workspace?
    public var sessions: [Session]
    public var pinned: Bool
    public var hidden: Bool
    public var note: String?
    public var lastActivity: Date
    public var running: Int
    public var waiting: Int
    public var parentId: String?
    public var envBranches: [String]?

    public var hasFolder: Bool { !(path ?? "").isEmpty }
    /// Checked out in a separate worktree folder, not the repo's main checkout.
    public var isLinkedWorktree: Bool { hasFolder && !mainWorktree }
    public var isOpen: Bool { workspace != nil }
    public var isFolded: Bool { !(parentId ?? "").isEmpty }
    public var latestSession: Session? { sessions.first }
    public var displayName: String { "\(repoLabel) \(branch)" }
}

public struct Counts: Codable, Hashable, Sendable {
    public var running: Int
    public var waiting: Int
    public var open: Int
    public var tasks: Int
}

public struct Snapshot: Codable, Sendable {
    public var generatedAt: Date
    public var cmuxRunning: Bool
    public var repos: [Repo]?
    public var tasks: [WkTask]?
    public var sessions: [Session]?
    public var counts: Counts

    public static let empty = Snapshot(generatedAt: .distantPast, cmuxRunning: false, repos: [], tasks: [], sessions: [],
                                       counts: Counts(running: 0, waiting: 0, open: 0, tasks: 0))
}

public struct TaskDetail: Codable, Sendable {
    public var task: WkTask
    public var log: [String]?
    public var changes: [String]?
}

public struct OpenResult: Codable, Sendable {
    public var action: String
    public var workspace: String?
    public var cwd: String
    public var command: String?
    public var message: String
}

public struct NewTaskResult: Codable, Sendable {
    public var taskId: String
    public var branch: String
    public var path: String
    public var base: String
    public var setupCmd: String?
    public var opened: OpenResult?
}

public struct RepoRefs: Codable, Sendable {
    public var repo: String
    public var baseBranch: String
    public var local: [String]
    public var remote: [String]
    public var worktrees: [String]
    public var suggestedPrefix: String
}

public struct RemoveOption: Codable, Hashable, Sendable {
    public var available: Bool
    public var `default`: Bool
    public var reason: String?
}

public struct RemoveFacts: Codable, Sendable {
    public var dirty: Int
    public var changes: [String]?
    public var unpushed: Int
    public var hasRemote: Bool
    public var merged: Bool
    public var sessions: Int
    public var liveSessions: Int
    public var workspace: Workspace?
    public var mainWorktree: Bool
}

public struct RemovePlan: Codable, Sendable {
    public var task: WkTask
    public var facts: RemoveFacts
    public var options: [String: RemoveOption]
    public var requiresConfirm: Bool
    public var blocked: String?
}

public enum RemoveOptionKey: String, CaseIterable, Sendable {
    case closeWorkspace = "close_workspace"
    case switchMainToBase = "switch_main_to_base"
    case removeWorktree = "remove_worktree"
    case deleteBranch = "delete_branch"
    case deleteRemote = "delete_remote"
    case trashSessions = "trash_sessions"

    public var label: String {
        switch self {
        case .closeWorkspace: "Close the cmux workspace"
        case .switchMainToBase: "Switch the main folder to the base branch"
        case .removeWorktree: "Remove the worktree folder"
        case .deleteBranch: "Delete the local branch"
        case .deleteRemote: "Delete the remote branch (origin)"
        case .trashSessions: "Move its Claude sessions to trash (restorable)"
        }
    }
}

public struct StepResult: Codable, Hashable, Sendable {
    public var step: String
    public var ok: Bool
    public var message: String
}

public struct CleanupItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var repo: String
    public var repoName: String
    public var branch: String?
    public var path: String?
    public var title: String
    public var reason: String
    public var safe: Bool
    public var dirty: Int
    public var unpushed: Int
    public var last: Date

    public var kindLabel: String {
        switch kind {
        case "merged": "Merged"
        case "gone": "Remote deleted"
        case "missing_worktree": "Folder missing"
        case "stale": "Stale"
        case "orphan_session": "Orphan session"
        default: kind
        }
    }
}

/// One terminal of a new cmux workspace. Kinds: claude, server, setup, shell, command.
public struct PaneConfig: Codable, Hashable, Sendable {
    public var kind: String
    public var name: String?
    public var command: String?
    public init(kind: String, name: String? = nil, command: String? = nil) {
        self.kind = kind
        self.name = name
        self.command = command
    }

    public static let kinds: [(id: String, label: String, about: String)] = [
        ("claude", "Claude", "Runs Claude, fresh or resuming the task's session."),
        ("server", "Server", "Runs the repo's server command (Settings → Repos)."),
        ("setup", "Setup", "Runs a new worktree's install steps, then stays open as a terminal."),
        ("shell", "Terminal", "An empty terminal in the task's folder."),
        ("command", "Command", "Runs the command you type here."),
    ]

    /// The tab title cmux shows, mirroring the core's defaults.
    public var title: String {
        if let name, !name.isEmpty { return name }
        if kind == "command", let first = command?.split(separator: " ").first { return String(first) }
        return Self.kinds.first { $0.id == kind }?.label ?? "Terminal"
    }
}

/// The panes of a new cmux workspace and how they are arranged.
public struct LayoutConfig: Codable, Hashable, Sendable {
    public var arrange: String
    public var mainSize: Int?
    public var panes: [PaneConfig]
    public init(arrange: String, mainSize: Int? = nil, panes: [PaneConfig]) {
        self.arrange = arrange
        self.mainSize = mainSize
        self.panes = panes
    }

    public static let maxPanes = 6
    public static let standard = LayoutConfig(arrange: "main-left", mainSize: 60,
                                              panes: [PaneConfig(kind: "claude"), PaneConfig(kind: "server"), PaneConfig(kind: "shell", name: "Git")])

    public static let arrangements: [(id: String, label: String)] = [
        ("main-left", "Main left"), ("main-right", "Main right"), ("main-top", "Main top"),
        ("columns", "Columns"), ("rows", "Rows"), ("grid", "Grid"), ("tabs", "Tabs"),
    ]

    public var usesMainSize: Bool { arrange.hasPrefix("main-") && panes.count > 1 }

    /// Where each pane sits in a unit square, in pane order. Mirrors the core's BuildLayout.
    public func frames() -> [CGRect] {
        let count = panes.count
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard count > 1, arrange != "tabs" else { return Array(repeating: unit, count: max(count, 1)) }
        let main = CGFloat(min(max(mainSize ?? 60, 20), 80)) / 100
        func stack(_ rect: CGRect, _ n: Int, vertical: Bool) -> [CGRect] {
            let parts = CGFloat(n)
            return (0..<n).map { index -> CGRect in
                let step = CGFloat(index) / parts
                if vertical {
                    return CGRect(x: rect.minX, y: rect.minY + rect.height * step, width: rect.width, height: rect.height / parts)
                }
                return CGRect(x: rect.minX + rect.width * step, y: rect.minY, width: rect.width / parts, height: rect.height)
            }
        }
        switch arrange {
        case "columns": return stack(unit, count, vertical: false)
        case "rows": return stack(unit, count, vertical: true)
        case "grid":
            let half = (count + 1) / 2
            return stack(CGRect(x: 0, y: 0, width: 0.5, height: 1), half, vertical: true)
                + stack(CGRect(x: 0.5, y: 0, width: 0.5, height: 1), count - half, vertical: true)
        case "main-right":
            return [CGRect(x: 1 - main, y: 0, width: main, height: 1)] + stack(CGRect(x: 0, y: 0, width: 1 - main, height: 1), count - 1, vertical: true)
        case "main-top":
            return [CGRect(x: 0, y: 0, width: 1, height: main)] + stack(CGRect(x: 0, y: main, width: 1, height: 1 - main), count - 1, vertical: false)
        default:
            return [CGRect(x: 0, y: 0, width: main, height: 1)] + stack(CGRect(x: main, y: 0, width: 1 - main, height: 1), count - 1, vertical: true)
        }
    }
}

public struct RepoSettings: Codable, Hashable, Sendable {
    public var serverCmd: String?
    public var baseBranch: String?
    public var postWorktree: [String]?
    public var noLayout: Bool?
    public var layout: LayoutConfig?
    public init(serverCmd: String? = nil, baseBranch: String? = nil, postWorktree: [String]? = nil, noLayout: Bool? = nil, layout: LayoutConfig? = nil) {
        self.serverCmd = serverCmd
        self.baseBranch = baseBranch
        self.postWorktree = postWorktree
        self.noLayout = noLayout
        self.layout = layout
    }
}

public struct WkConfig: Codable, Hashable, Sendable {
    public var roots: [String]
    public var baseBranch: String
    public var recentDays: Int
    public var claudeDir: String
    public var cmuxBin: String?
    public var gitBin: String?
    public var hotkey: String?
    public var autoStartClaude: Bool?
    public var labelStripPrefixes: [String]?
    public var layout: LayoutConfig?
    public var repos: [String: RepoSettings]?
}

public struct Message: Codable, Sendable {
    public var message: String
}

public enum JSON {
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = parseDate(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad date \(text)")
        }
        return decoder
    }()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    /// Go writes RFC 3339 with optional nanoseconds; the zero time means "never".
    public static func parseDate(_ text: String) -> Date? {
        if text.hasPrefix("0001-01-01") { return .distantPast }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        // Trim nanoseconds to milliseconds, which ISO8601DateFormatter understands.
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = text[text.index(after: dot)..<zone].prefix(3)
            if let date = withFraction.date(from: String(text[..<dot]) + "." + fraction + String(text[zone...])) { return date }
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
