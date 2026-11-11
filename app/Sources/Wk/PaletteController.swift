import AppKit
import SwiftUI

/// Borderless full-screen panel that can take keyboard focus without a Dock icon (launcher-style).
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        PaletteController.shared.escape()
    }
}

@MainActor
final class PaletteController: NSObject, NSWindowDelegate {
    static let shared = PaletteController()

    private var panel: PalettePanel?
    private(set) var store: AppStore?
    var isVisible: Bool { panel?.isVisible == true }

    func attach(_ store: AppStore) {
        self.store = store
    }

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                                 styleMask: [.borderless, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Above the menu bar and Dock, so the palette owns the whole screen while it is open.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
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

    func toggle() {
        isVisible ? hide() : show()
    }

    func show(overlay: Overlay? = nil, tab: PaletteTab? = nil) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let store {
            if let tab { store.tab = tab }
            store.overlay = overlay
            store.refresh(.all)
            if store.tab == .cleanup { store.loadCleanup() }
            if store.tab == .sessions { store.searchSessions() }
        }
        if !panel.isVisible { fillScreen(panel) }
        activateApp()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        // SwiftUI's onAppear only fires once; refocus the search field on every show.
        DispatchQueue.main.async { NotificationCenter.default.post(name: .wkFocusSearch, object: nil) }
    }

    /// macOS 14+ cooperative activation can refuse an accessory app; the legacy call still forces it,
    /// which is what a hotkey launcher needs.
    @available(macOS, deprecated: 14)
    private func forceActivate() { NSApp.activate(ignoringOtherApps: true) }

    private func activateApp() {
        NSApp.activate()
        if !NSApp.isActive { forceActivate() }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        // Hand keyboard focus back to whatever app was in front before the palette.
        if NSApp.isActive { NSApp.hide(nil) }
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
            if NSApp.keyWindow == nil || NSApp.keyWindow !== self.panel { self.hide() }
        }
    }
}

extension Notification.Name {
    static let wkFocusSearch = Notification.Name("wkFocusSearch")
}
