import Foundation
import UserNotifications

/// Posts macOS notifications when a tab signals activity (e.g. a coding
/// agent finishes or asks a question — the convention is to ring the
/// terminal bell). Per-tab debounce keeps a runaway shell from flooding
/// Notification Center.
@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private var lastNotification: [UUID: Date] = [:]
    private let debounceInterval: TimeInterval = 2.0

    private init() {}

    func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func notifyActivity(workspaceName: String, tabId: UUID, tabTitle: String) {
        let now = Date()
        if let last = lastNotification[tabId], now.timeIntervalSince(last) < debounceInterval {
            return
        }
        lastNotification[tabId] = now

        let content = UNMutableNotificationContent()
        content.title = workspaceName
        let trimmedTitle = tabTitle.trimmingCharacters(in: .whitespaces)
        content.body = trimmedTitle.isEmpty
            ? "Agent activity in shell"
            : "Agent activity in \(trimmedTitle)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "clayspace.activity.\(tabId.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
