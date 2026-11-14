import AppKit

/// Where a task opens when cmux isn't available. A throwaway `.command` script is used instead of
/// AppleScript, so macOS never asks for Automation permission.
enum FallbackTerminal: String, CaseIterable, Identifiable {
    case auto, terminal, iterm, copy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Automatic"
        case .terminal: "Terminal"
        case .iterm: "iTerm"
        case .copy: "Copy the command"
        }
    }

    private static let bundleIDs: [FallbackTerminal: String] = [
        .terminal: "com.apple.Terminal",
        .iterm: "com.googlecode.iterm2",
    ]

    static var current: FallbackTerminal {
        get { UserDefaults.standard.string(forKey: "fallbackTerminal").flatMap(FallbackTerminal.init) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "fallbackTerminal") }
    }

    static func appURL(_ terminal: FallbackTerminal) -> URL? {
        bundleIDs[terminal].flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// The app that will actually be used: auto prefers iTerm when it's installed.
    var resolved: FallbackTerminal {
        guard self == .auto else { return self }
        return Self.appURL(.iterm) != nil ? .iterm : .terminal
    }

    /// Runs `command` in a new terminal window and returns the toast text. Falls back to the clipboard.
    @discardableResult
    static func run(_ command: String) -> String {
        let choice = current.resolved
        guard choice != .copy, let app = appURL(choice), let script = try? writeScript(command) else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            return "cmux isn't available — command copied to clipboard"
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([script], withApplicationAt: app, configuration: configuration)
        return "cmux isn't available — opened in \(choice.label)"
    }

    /// The script deletes itself, runs the command in the user's login shell (so `claude` is on PATH)
    /// and leaves that shell open afterwards.
    static func scriptBody(_ command: String) -> String {
        let inner = "\(command); exec \"${SHELL:-/bin/zsh}\" -l"
        let quoted = "'" + inner.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/sh
        rm -f -- "$0"
        clear
        exec "${SHELL:-/bin/zsh}" -l -i -c \(quoted)

        """
    }

    private static func writeScript(_ command: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wk-open-\(UUID().uuidString.prefix(8)).command")
        try scriptBody(command).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
