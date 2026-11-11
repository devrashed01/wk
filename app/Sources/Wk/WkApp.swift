import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications
import WkKit

@main
struct WkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The app lives in the menu bar as a plain NSStatusItem (set up in AppDelegate), so a
        // click can act instead of opening a dropdown. SwiftUI needs one Scene; a never-inserted
        // MenuBarExtra contributes no UI (a Settings scene here gets shown on app reopen).
        MenuBarExtra("Wk", isInserted: .constant(false)) { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = AppStore()
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        PaletteController.shared.attach(store)
        ActivityHUD.shared.attach(store)
        hotKey = HotKey { Task { @MainActor in PaletteController.shared.toggle() } }
        applyHotKey()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            Notifier.requestPermission()
        }
        store.start()
        setUpStatusItem()
        observeStatus()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    // MARK: Menu bar

    /// The menu-bar icon is a button, not a dropdown: left-click toggles the palette (same as the
    /// hotkey), right-click shows a minimal menu (Open, Settings, Quit — Quit must live somewhere).
    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            button.image = Self.brandIcon()
            button.toolTip = "Wk — \(HotKey.combo(for: UserDefaults.standard.string(forKey: "hotkey")).label)"
        }
        statusItem = item
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            PaletteController.shared.toggle()
        }
    }

    private func showStatusMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Wk", action: #selector(openPalette), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Wk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil  // hand the button back to the left-click action
    }

    /// The brand mark (same geometry as the app icon) as an 18pt template image, so it follows
    /// the menu bar's light/dark appearance like a native status icon.
    private static func brandIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Glyph bounds in the icon's 1024 space (stroke caps included): x 331–693, y 239–785.
            let scale: CGFloat = 16 / 546
            ctx.translateBy(x: (18 - 362 * scale) / 2, y: 1)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -331, y: -239)
            ctx.setLineWidth(58)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.move(to: CGPoint(x: 360, y: 268)); ctx.addLine(to: CGPoint(x: 360, y: 756)); ctx.strokePath()
            let k: CGFloat = 0.5523
            for (a, b) in [(CGPoint(x: 360, y: 330), CGPoint(x: 664, y: 520)),
                           (CGPoint(x: 360, y: 510), CGPoint(x: 664, y: 700))] {
                ctx.move(to: a)
                ctx.addCurve(to: b, control1: CGPoint(x: a.x, y: a.y + k * (b.y - a.y)),
                             control2: CGPoint(x: b.x - k * (b.x - a.x), y: b.y))
                ctx.strokePath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func openPalette() { PaletteController.shared.show() }
    @objc private func openSettings() { PaletteController.shared.show(tab: .settings) }

    /// Keeps the icon live: the symbol tracks whether Claude is working, the badge counts
    /// sessions waiting for you. Re-arms itself on every store change.
    private func observeStatus() {
        withObservationTracking {
            applyStatus(store.status)
        } onChange: {
            Task { @MainActor [weak self] in self?.observeStatus() }
        }
    }

    /// The brand mark stays constant; the only live signal is the count of sessions waiting for you.
    private func applyStatus(_ status: MenuBarStatus) {
        guard let button = statusItem?.button else { return }
        button.title = status.badge.isEmpty ? "" : " " + status.badge
    }

    /// Double-clicking Wk.app in Finder (or `open Wk.app`) opens the palette.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PaletteController.shared.show()
        return false
    }

    func applyHotKey() {
        let combo = HotKey.combo(for: UserDefaults.standard.string(forKey: "hotkey"))
        if hotKey?.register(combo) == false {
            store.toast = "⚠︎ \(combo.label) is used by another app — pick another hotkey in Settings"
        }
    }

    /// wk://palette · wk://new · wk://sessions · wk://cleanup · wk://open?task=<id>
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else { return }
        let controller = PaletteController.shared
        switch url.host {
        case "new": controller.show(overlay: .newTask(NewTaskSeed()), tab: .tasks)
        case "sessions": controller.show(tab: .sessions)
        case "cleanup": controller.show(tab: .cleanup)
        case "settings": controller.show(tab: .settings)
        case "open":
            let taskID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "task" }?.value
            if let taskID, let task = store.task(taskID) { store.open(task) } else { controller.show() }
        default: controller.show(tab: .tasks)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let taskID = info[Notifier.taskKey] as? String ?? ""
        let sessionID = info[Notifier.sessionKey] as? String ?? ""
        await MainActor.run {
            if let task = store.task(taskID) {
                store.open(task, session: sessionID.isEmpty ? nil : sessionID)
            } else if let session = store.session(sessionID) {
                store.resume(session)
            } else {
                PaletteController.shared.show()
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
    }
}
