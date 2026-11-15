import Foundation

/// The Bitbucket API token lives in the login Keychain as a generic password (service "wk.bitbucket",
/// account = the Bitbucket email). It is written with /usr/bin/security and marked readable by that
/// tool, so the Go core can read it with `security find-generic-password` without a prompt.
enum BitbucketToken {
    static let service = "wk.bitbucket"

    static func isSaved(for user: String) -> Bool {
        guard !user.isEmpty else { return false }
        return security(["find-generic-password", "-s", service, "-a", user]) == 0
    }

    /// Returns an error message, or nil on success.
    static func save(_ token: String, for user: String) -> String? {
        guard !user.isEmpty else { return "Enter your Bitbucket email first." }
        let status = security(["add-generic-password", "-U", "-s", service, "-a", user, "-l", "wk Bitbucket token",
                               "-T", "/usr/bin/security", "-w", token])
        return status == 0 ? nil : "Couldn't save to the Keychain (security exited with \(status))."
    }

    static func delete(for user: String) {
        _ = security(["delete-generic-password", "-s", service, "-a", user])
    }

    private static func security(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
