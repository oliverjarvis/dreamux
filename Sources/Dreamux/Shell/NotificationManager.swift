import Foundation
import Observation
import UserNotifications
import AppKit
import os

/// The narrow slice of `UNUserNotificationCenter` the manager uses.
/// A protocol so tests can assert what would have been posted without a
/// real notification centre — which is unavailable under the e2e
/// harness anyway, since it deliberately skips the permission prompt.
@MainActor
protocol NotificationPosting: AnyObject {
    func setCategories(_ categories: Set<UNNotificationCategory>)
    func post(_ notification: AttentionNotification)
    func withdraw(identifiers: [String])
}

@MainActor
final class SystemNotificationPoster: NotificationPosting {
    func setCategories(_ categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    func post(_ notification: AttentionNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = notification.threadIdentifier
        content.categoryIdentifier = notification.categoryIdentifier
        content.targetContentIdentifier = notification.identifier
        content.userInfo = notification.userInfo
        content.interruptionLevel = notification.urgency == .timeSensitive ? .timeSensitive : .active

        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NotificationManager.reportPostFailure(error) }
        }
    }

    func withdraw(identifiers: [String]) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Posts macOS notifications when a tab's agent wants the user —
/// blocked on a decision, or finished a turn. Per-tab debounce keeps a
/// runaway shell from flooding Notification Center.
@MainActor
@Observable
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    var poster: NotificationPosting = SystemNotificationPoster()

    /// Installed by the app so a banner interaction can reach the store
    /// that owns workspaces. Set in `DreamuxApp`.
    var onRoute: ((NotificationRoute) -> Void)?

    /// Whether banners can actually be delivered. Observed by the
    /// sidebar, which shows a row when this is anything but healthy —
    /// the whole point being that a delivery failure is visible instead
    /// of buried in `os_log`.
    private(set) var health: NotificationHealth = .unknown

    /// Debounce per tab AND per state rank: a runaway shell cannot
    /// flood, but a `working → blocked` transition is never eaten by a
    /// banner posted moments earlier for a different state.
    private struct DebounceKey: Hashable { let tabID: UUID; let rank: Int }
    private var lastNotification: [DebounceKey: Date] = [:]
    private let debounceInterval: TimeInterval = 2.0

    private override init() {
        super.init()
        // Becoming the delegate lets us override the default behaviour
        // where macOS suppresses notifications while our app is frontmost
        // (see `userNotificationCenter(_:willPresent:withCompletionHandler:)`).
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }

    private func registerCategories() {
        let open = UNNotificationAction(
            identifier: NotificationActionID.open, title: "Open", options: [.foreground]
        )
        let dismiss = UNNotificationAction(
            identifier: NotificationActionID.dismiss, title: "Dismiss", options: []
        )
        let approve = UNNotificationAction(
            identifier: NotificationActionID.approve, title: "Approve", options: []
        )
        let deny = UNNotificationAction(
            identifier: NotificationActionID.deny, title: "Deny", options: []
        )
        poster.setCategories([
            UNNotificationCategory(identifier: NotificationCategoryID.blockedPermission,
                                   actions: [approve, deny, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: NotificationCategoryID.blocked,
                                   actions: [open, dismiss], intentIdentifiers: []),
            UNNotificationCategory(identifier: NotificationCategoryID.done,
                                   actions: [open], intentIdentifiers: []),
        ])
    }

    /// Open System Settings on the per-app Notifications pane. Useful
    /// after macOS denied us — `requestAuthorization` won't re-prompt
    /// once status is `.denied`, so the user has to flip the switch.
    func openSystemNotificationSettings() {
        let bundleID = BundleIdentity.bundleID()
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
                    // Description lifted out here: `any Error` is not
                    // Sendable and cannot cross to the main actor.
                    let failure = error?.localizedDescription
                    Task { @MainActor in
                        if let failure {
                            NotificationManager.shared.health = .failed(failure)
                        } else {
                            NotificationManager.shared.health = granted ? .healthy : .denied
                        }
                    }
                    Self.log("authorization request — granted=\(granted), error=\(String(describing: error))")
                }
            case .denied:
                Task { @MainActor in NotificationManager.shared.health = .denied }
                Self.log("authorization status: denied — enable in System Settings → Notifications → Dreamux")
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in NotificationManager.shared.health = .healthy }
                Self.log("authorization status: authorized")
            @unknown default:
                Self.log("authorization status: unknown")
            }
        }
    }

    /// Post (or replace) the banner for one tab's attention state.
    /// Returns the notification that was posted, or nil when the state
    /// does not warrant one — the return value exists so callers and
    /// tests can see the decision.
    @discardableResult
    func notify(
        workspaceName: String,
        workspaceID: UUID,
        tabID: UUID,
        tabTitle: String,
        harnessDisplayName: String,
        attention: AgentAttention,
        hasVerifiedPermissionRecipe: Bool
    ) -> AttentionNotification? {
        guard let notification = AttentionNotification.make(
            workspaceName: workspaceName,
            workspaceID: workspaceID,
            tabID: tabID,
            tabTitle: tabTitle,
            harnessDisplayName: harnessDisplayName,
            attention: attention,
            hasVerifiedPermissionRecipe: hasVerifiedPermissionRecipe
        ) else {
            // Nothing waiting: retract any banner still on screen for
            // this tab rather than leaving a stale one up.
            poster.withdraw(identifiers: ["dreamux.attention.\(tabID.uuidString)"])
            return nil
        }
        let now = Date()
        let key = DebounceKey(tabID: tabID, rank: attention.rank)
        if let last = lastNotification[key], now.timeIntervalSince(last) < debounceInterval {
            return nil
        }
        lastNotification[key] = now
        poster.post(notification)
        return notification
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

    // `nonisolated`: every caller is a `UNUserNotificationCenter`
    // completion handler running off the main actor, and `Logger` is
    // Sendable, so there is nothing to isolate.
    nonisolated private static let logger = Logger(
        subsystem: "com.dreamux.Dreamux",
        category: "Notifications"
    )

    /// `nonisolated` because every caller is a `UNUserNotificationCenter`
    /// completion handler, which runs off the main actor.
    /// One-shot provenance report for "no banners ever appear". Prints
    /// authorization status, the bundle identity notifications are
    /// registered under, and the outcome of a probe post. Reach it from
    /// the app menu; it writes to the unified log under the
    /// `Notifications` category.
    func runDiagnostic() {
        let bundleID = BundleIdentity.bundleID()
        Self.log("diagnostic: bundleID=\(bundleID)")
        Self.log("diagnostic: bundlePath=\(Bundle.main.bundleURL.path)")
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Self.log("diagnostic: authorizationStatus=\(settings.authorizationStatus.rawValue)")
            Self.log("diagnostic: alertSetting=\(settings.alertSetting.rawValue)")
            let content = UNMutableNotificationContent()
            content.title = "Dreamux"
            content.body = "Notification diagnostic"
            let probe = UNNotificationRequest(
                identifier: "dreamux.diagnostic", content: content, trigger: nil
            )
            UNUserNotificationCenter.current().add(probe) { error in
                if let error {
                    let description = error.localizedDescription
                    Self.log("diagnostic: probe FAILED — \(description)")
                    Task { @MainActor in
                        NotificationManager.shared.health = .failed(description)
                    }
                } else {
                    Self.log("diagnostic: probe posted")
                    Task { @MainActor in NotificationManager.shared.health = .healthy }
                }
            }
        }
    }

    nonisolated static func reportPostFailure(_ error: Error) {
        let description = error.localizedDescription
        Task { @MainActor in
            log("post failed: \(description)")
            NotificationManager.shared.health = .failed(description)
        }
    }

    nonisolated private static func log(_ message: String) {
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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Decode before hopping: `userInfo` is `[AnyHashable: Any]` and
        // the completion handler is not Sendable, so neither may cross
        // to the main actor. `NotificationRoute` is plain value data and
        // can.
        let route = NotificationRoute(
            userInfo: response.notification.request.content.userInfo,
            actionIdentifier: response.actionIdentifier
        )
        if let route {
            Task { @MainActor in NotificationManager.shared.onRoute?(route) }
        }
        completionHandler()
    }
}
