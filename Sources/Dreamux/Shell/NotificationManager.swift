import Foundation
import UserNotifications
import AppKit
import os

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

    /// Open System Settings on the per-app Notifications pane. Useful
    /// after macOS denied us — `requestAuthorization` won't re-prompt
    /// once status is `.denied`, so the user has to flip the switch.
    func openSystemNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.dreamux.Dreamux"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)") {
            NSWorkspace.shared.open(url)
        }
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
                Self.log("authorization status: denied — enable in System Settings → Notifications → Dreamux")
            case .authorized, .provisional, .ephemeral:
                Self.log("authorization status: authorized")
            @unknown default:
                Self.log("authorization status: unknown")
            }
        }
    }

    func notifyActivity(
        workspaceName: String,
        tabId: UUID,
        tabTitle: String,
        message: String? = nil
    ) {
        let now = Date()
        if let last = lastNotification[tabId], now.timeIntervalSince(last) < debounceInterval {
            return
        }
        lastNotification[tabId] = now

        let content = UNMutableNotificationContent()
        content.title = workspaceName

        let trimmedTitle = tabTitle.trimmingCharacters(in: .whitespaces)
        let trimmedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedMessage, !trimmedMessage.isEmpty {
            content.subtitle = trimmedTitle.isEmpty ? "shell" : trimmedTitle
            content.body = trimmedMessage
        } else {
            content.body = trimmedTitle.isEmpty
                ? "Agent activity in shell"
                : "Agent activity in \(trimmedTitle)"
        }
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "dreamux.activity.\(tabId.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.log("post failed for \(workspaceName) / \(trimmedTitle): \(error)")
            }
        }
    }

    /// One-shot generic notification (no per-tab debounce) — used for
    /// unattended failures the user isn't watching for, like an auto-run
    /// launch that couldn't provision its worktree.
    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(
            identifier: "dreamux.event.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Self.log("post failed for \(title): \(error)") }
        }
    }

    private static let logger = Logger(
        subsystem: "com.dreamux.Dreamux",
        category: "Notifications"
    )

    private static func log(_ message: String) {
        // Use unified logging so the user can grep with:
        //   log show --predicate 'subsystem == "com.dreamux.Dreamux"' --info --last 5m
        logger.info("\(message, privacy: .public)")
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner + sound even while Dreamux is the foreground app —
        // otherwise the user types `printf '\a'` and sees nothing.
        completionHandler([.banner, .sound, .list])
    }
}
