import Foundation

/// wk's custom right-sidebar panel for cmux (Resources/cmux-panel.js), installed as
/// ~/.config/cmux/sidebars/wk.js. cmux hot-reloads the file, so updates show at once.
enum CmuxPanel {
    static var target: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/cmux/sidebars/wk.js")
    }

    static var bundled: URL? { Bundle.main.url(forResource: "cmux-panel", withExtension: "js") }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: target.path) }

    /// Copies the bundled panel. Returns an error message, or nil.
    @discardableResult
    static func install() -> String? {
        guard let bundled, let script = try? Data(contentsOf: bundled) else { return "This build of wk has no cmux panel." }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: target, options: .atomic)
            return nil
        } catch {
            return "Couldn't write \(target.path): \(error.localizedDescription)"
        }
    }

    /// Keeps an installed panel in step with this version of wk.
    static func updateIfInstalled() {
        guard isInstalled, let bundled, let script = try? Data(contentsOf: bundled),
              (try? Data(contentsOf: target)) != script else { return }
        install()
    }

    static func uninstall() { try? FileManager.default.removeItem(at: target) }

    /// Opens the panel in cmux's right sidebar. Returns a status line for the settings page.
    static func show() -> String {
        let bin = ["/Applications/cmux.app/Contents/Resources/bin/cmux",
                   FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/cmux.app/Contents/Resources/bin/cmux").path]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let bin else { return "Installed. In cmux, open the right sidebar and pick Custom → wk." }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["right-sidebar", "set", "custom", "wk"]
        process.environment = ProcessInfo.processInfo.environment.merging(["CMUX_QUIET": "1"]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var shown = false
        if (try? process.run()) != nil {
            process.waitUntilExit()
            shown = process.terminationStatus == 0
        }
        return shown
            ? "Showing in cmux's right sidebar. Switch back to it any time from the sidebar's mode bar (Custom)."
            : "Installed. cmux isn't reachable right now — in cmux, open the right sidebar and pick Custom → wk."
    }
}
