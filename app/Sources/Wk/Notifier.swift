import Foundation
import UserNotifications
import WkKit

/// Local notifications. Clicking a "Claude is waiting" notification jumps to that task.
enum Notifier {
    static let taskKey = "taskID"
    static let sessionKey = "sessionID"
    static let urlKey = "url"

    static func requestPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func claudeWaiting(session: Session, task: WkTask?) {
        let content = UNMutableNotificationContent()
        content.title = "Claude is waiting for you"
        content.subtitle = task?.displayName ?? PathDisplay.collapse(session.cwd)
        content.body = session.displayTitle
        content.userInfo = [taskKey: task?.id ?? "", sessionKey: session.id]
        post(content, id: "waiting-\(session.id)")
    }

    static func pullRequest(_ alert: PRAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.headline
        content.subtitle = alert.title
        content.body = alert.pr.title
        content.userInfo = [taskKey: alert.taskID, urlKey: alert.pr.url]
        post(content, id: "pr-\(alert.pr.url)-\(alert.kind)")
    }

    static func result(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        post(content, id: UUID().uuidString)
    }

    private static func post(_ content: UNMutableNotificationContent, id: String) {
        guard Bundle.main.bundleIdentifier != nil else { return } // not running as a bundled app
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
