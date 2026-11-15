import Foundation

/// API tokens live in the login Keychain as generic passwords (service "wk.bitbucket" / "wk.jira",
/// account = the Atlassian email). They're written with /usr/bin/security and marked readable by
/// that tool, so the Go core can read them with `security find-generic-password` without a prompt.
struct KeychainToken {
    let service: String

    static let bitbucket = KeychainToken(service: "wk.bitbucket")
    static let jira = KeychainToken(service: "wk.jira")

    func isSaved(for user: String) -> Bool {
        guard !user.isEmpty else { return false }
        return Self.security(["find-generic-password", "-s", service, "-a", user]).status == 0
    }

    func read(for user: String) -> String? {
        guard !user.isEmpty else { return nil }
        let result = Self.security(["find-generic-password", "-s", service, "-a", user, "-w"])
        let token = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !token.isEmpty ? token : nil
    }

    /// Returns an error message, or nil on success.
    func save(_ token: String, for user: String) -> String? {
        guard !user.isEmpty else { return "Enter your Atlassian email first." }
        let status = Self.security(["add-generic-password", "-U", "-s", service, "-a", user, "-l", "wk \(service) token",
                                    "-T", "/usr/bin/security", "-w", token]).status
        return status == 0 ? nil : "Couldn't save to the Keychain (security exited with \(status))."
    }

    func delete(for user: String) {
        _ = Self.security(["delete-generic-password", "-s", service, "-a", user])
    }

    private static func security(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
