import AppKit
import SwiftUI

/// Borderless full-screen panel that can take keyboard focus without a Dock icon (launcher-style).
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        PaletteController.shared.escape()
    }
}

@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    static let shared = PaletteController()

    private var panel: PalettePanel?
    private(set) var store: AppStore?
    /// Visible means actually on a live screen. After sleep, display changes or a long uptime the
    /// panel can claim to be visible while it sits on a screen that's gone, which made the hotkey
    /// "hide" an invisible window and look dead.
    var isVisible: Bool { panel.map { $0.isVisible && $0.screen != nil && $0.windowNumber > 0 } ?? false }

    func attach(_ store: AppStore) {
        self.store = store
    }

    private func makePanel() -> PalettePanel {
        // .nonactivatingPanel is the Spotlight trick: the panel takes keyboard focus without
        // activating the app, so macOS never switches Spaces — it appears right over whatever
        // is frontmost, full-screen apps included.
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                                 styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Above full-screen apps and their menu bar while the palette is open.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        if let store {
            panel.contentView = NSHostingView(rootView: PaletteView().environment(store))
        }
        return panel
    }

    /// Lets the user pick a folder in a Finder sheet attached to the palette, so the palette
    /// stays open (a separate window would take focus and dismiss it).
    func chooseFolder(_ done: @escaping (URL) -> Void) {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.prompt = "Add"
        open.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if let panel {
            open.beginSheetModal(for: panel) { response in
                if response == .OK, let url = open.url { done(url) }
            }
        } else if open.runModal() == .OK, let url = open.url {
            done(url)
        }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show(overlay: Overlay? = nil, tab: PaletteTab? = nil) {
        // Rebuild the panel if the window server dropped its window or its screen went away.
        if let old = self.panel, old.windowNumber <= 0 || (old.isVisible && old.screen == nil) {
            old.orderOut(nil)
            self.panel = nil
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let store {
            if let tab { store.tab = tab }
            store.overlay = overlay
            store.refresh(.all)
            if store.tab == .cleanup { store.loadCleanup() }
            if store.tab == .sessions { store.searchSessions() }
        }
        if !isVisible { fillScreen(panel) }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        // SwiftUI's onAppear only fires once; refocus the search field on every show.
        DispatchQueue.main.async { NotificationCenter.default.post(name: .wkFocusSearch, object: nil) }
        ActivityHUD.shared.refresh()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        // The app was never activated (non-activating panel), so focus falls straight back to
        // whatever app was in front — no Space switch either way.
        if NSApp.isActive { NSApp.hide(nil) }
        ActivityHUD.shared.refresh()
    }

    /// Esc closes the innermost layer first: overlay, then search text, then the panel.
    func escape() {
        guard let store else { hide(); return }
        if store.overlay != nil {
            store.overlay = nil
        } else if !store.query.isEmpty {
            store.query = ""
        } else {
            hide()
        }
    }

    /// Covers the whole screen under the mouse (re-applied on every show, the user may have moved screens).
    private func fillScreen(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        panel.setFrame(frame, display: true)
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            // Clicking elsewhere dismisses the palette, like Spotlight.
            // A sheet on the palette (folder picker) takes key status; that isn't "clicking elsewhere".
            if let key = NSApp.keyWindow, key === self.panel || key.sheetParent === self.panel { return }
            if self.panel?.attachedSheet != nil { return }
            self.hide()
        }
    }
}

extension Notification.Name {
    static let wkFocusSearch = Notification.Name("wkFocusSearch")
}
