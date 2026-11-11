import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications
import WkKit

@main
struct WkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(delegate.store)
        } label: {
            MenuBarLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let store: AppStore

    var body: some View {
        let status = store.status
        HStack(spacing: 2) {
            Image(systemName: status.symbol)
            if !status.badge.isEmpty { Text(status.badge) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = AppStore()
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        PaletteController.shared.attach(store)
        hotKey = HotKey { Task { @MainActor in PaletteController.shared.toggle() } }
        applyHotKey()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            Notifier.requestPermission()
        }
        store.start()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
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
