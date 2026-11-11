import CoreServices
import Foundation

/// What kind of input changed, so the core only rebuilds that part.
public struct ChangeScope: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let sessions = ChangeScope(rawValue: 1) // transcripts, cmux hook state
    public static let cmux = ChangeScope(rawValue: 2)     // workspaces opened/closed
    public static let git = ChangeScope(rawValue: 4)      // branches, worktrees, HEAD
    public static let all: ChangeScope = [.sessions, .cmux, .git]
}

/// Classifies a changed path into the scope it affects.
public enum ChangeClassifier {
    public static func scope(for path: String, claudeProjects: String, cmuxState: String) -> ChangeScope {
        if path.hasPrefix(claudeProjects) { return .sessions }
        if path.hasPrefix(cmuxState) {
            return path.contains("hook-sessions") ? [.sessions] : [.cmux, .sessions]
        }
        if path.contains("/.git") {
            // Ignore git's churn that does not change branches or worktrees.
            if path.hasSuffix("/index") || path.hasSuffix(".lock") || path.contains("/objects/") || path.contains("/logs/") || path.hasSuffix("FETCH_HEAD") {
                return []
            }
            return .git
        }
        return []
    }
}

/// FSEvents-based watcher: one recursive stream, kernel-coalesced, no polling.
public final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "wk.filewatcher")
    private let handler: @Sendable ([String]) -> Void

    public init(handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
    }

    public func watch(_ paths: [String], latency: TimeInterval = 1.0) {
        stop()
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handler(Array(array.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf)
        guard let created = FSEventStreamCreate(nil, callback, &context, existing as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
