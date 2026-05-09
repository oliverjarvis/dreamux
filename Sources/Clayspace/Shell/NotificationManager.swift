import Foundation
import UserNotifications

/// Posts macOS notifications when a tab signals activity (e.g. a coding
/// agent finishes or asks a question — the convention is to ring the
/// terminal bell). Per-tab debounce keeps a runaway shell from flooding
/// Notification Center.
@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    private var lastNotification: [UUID: Date] = [:]
    private let debounceInterval: TimeInterval = 2.0

    private override init() {
        super.init()
        // Becoming the delegate lets us override the default behaviour
        // where macOS suppresses notifications while our app is frontmost
        // (see `userNotificationCenter(_:willPresent:withCompletionHandler:)`).
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    Self.log("authorization request — granted=\(granted), error=\(String(describing: error))")
                }
            case .denied:
                Self.log("authorization status: denied — enable in System Settings → Notifications → Clayspace")
            case .authorized, .provisional, .ephemeral:
                Self.log("authorization status: authorized")
            @unknown default:
                Self.log("authorization status: unknown")
            }
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
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "clayspace.activity.\(tabId.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.log("post failed for \(workspaceName) / \(trimmedTitle): \(error)")
            }
        }
    }

    private static func log(_ message: String) {
        print("[Clayspace.Notifications] \(message)")
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner + sound even while Clayspace is the foreground app —
        // otherwise the user types `printf '\a'` and sees nothing.
        completionHandler([.banner, .sound, .list])
    }
}
