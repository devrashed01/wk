import Foundation

public struct CoreError: LocalizedError, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct ProgressEvent: Sendable {
    public let level: String
    public let message: String
    public var isWarning: Bool { level == "warn" }
}

/// Talks to a long-running `wk serve` process over newline-delimited JSON.
/// Requests are answered in order by the core; responses are matched by id.
public final class CoreClient: @unchecked Sendable {
    private let executable: URL
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [String: (Result<Data, Error>) -> Void] = [:]
    private var progressHandlers: [String: (ProgressEvent) -> Void] = [:]

    public init(executable: URL) {
        self.executable = executable
    }

    /// Finds the bundled core, then common install locations.
    public static func locateExecutable(bundle: Bundle = .main) -> URL? {
        var candidates: [URL] = []
        if let bundled = bundle.url(forResource: "wk", withExtension: nil) { candidates.append(bundled) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates += [
            home.appending(path: "go/bin/wk"),
            URL(fileURLWithPath: "/opt/homebrew/bin/wk"),
            URL(fileURLWithPath: "/usr/local/bin/wk"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func call<Response: Decodable>(_ command: String, _ args: some Encodable = [String: String](),
                                          as type: Response.Type = Response.self,
                                          progress: ((ProgressEvent) -> Void)? = nil) async throws -> Response {
        let line = try await raw(command, args: try JSON.encoder.encode(args), progress: progress)
        return try JSON.decoder.decode(DataEnvelope<Response>.self, from: line).data
    }

    private struct DataEnvelope<Payload: Decodable>: Decodable {
        var data: Payload
    }

    private func raw(_ command: String, args: Data, progress: ((ProgressEvent) -> Void)?) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            do {
                try startIfNeeded()
                nextID += 1
                let id = String(nextID)
                pending[id] = { continuation.resume(with: $0) }
                if let progress { progressHandlers[id] = progress }
                var line = Data("{\"id\":\"\(id)\",\"cmd\":\"\(command)\",\"args\":".utf8)
                line.append(args)
                line.append(Data("}\n".utf8))
                try input?.write(contentsOf: line)
                lock.unlock()
            } catch {
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    /// Must be called with the lock held.
    private func startIfNeeded() throws {
        if let process, process.isRunning { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPath = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/go/bin", "\(home)/.local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = (extraPath + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.failAll(CoreError(message: "wk core exited"))
                return
            }
            self?.receive(data)
        }
        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
        buffer = Data()
    }

    private func receive(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines { handle(line: Data(line)) }
    }

    private struct Envelope: Decodable {
        var id: String?
        var ok: Bool?
        var error: String?
        var event: String?
        var level: String?
        var message: String?
    }

    private func handle(line: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line), let id = envelope.id else { return }
        lock.lock()
        if envelope.event == "progress" {
            let handler = progressHandlers[id]
            lock.unlock()
            handler?(ProgressEvent(level: envelope.level ?? "step", message: envelope.message ?? ""))
            return
        }
        let completion = pending.removeValue(forKey: id)
        progressHandlers.removeValue(forKey: id)
        lock.unlock()
        if envelope.ok == true {
            completion?(.success(line))
        } else {
            completion?(.failure(CoreError(message: envelope.error ?? "unknown error")))
        }
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let waiting = pending
        pending.removeAll()
        progressHandlers.removeAll()
        process = nil
        lock.unlock()
        for completion in waiting.values { completion(.failure(error)) }
    }

    public func stop() {
        lock.lock()
        process?.terminate()
        process = nil
        lock.unlock()
    }
}
