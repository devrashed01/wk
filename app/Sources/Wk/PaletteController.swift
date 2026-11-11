import AppKit
import SwiftUI

/// Borderless floating panel that can take keyboard focus without a Dock icon (Spotlight-style).
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
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                                 styleMask: [.borderless, .fullSizeContentView, .resizable],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
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
        if !panel.isVisible { center(panel) }
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

    private func center(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.1))
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
