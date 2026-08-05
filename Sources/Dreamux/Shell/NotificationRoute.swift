import Foundation
import UserNotifications

/// Where a banner interaction points, decoded from the notification's
/// own `userInfo`. Pure, so the decision is testable without a
/// notification centre.
struct NotificationRoute: Equatable, Sendable {
    enum Intent: Equatable, Sendable { case open, dismiss, approve, deny }

    let workspaceID: UUID
    let tabID: UUID
    let requestID: String
    let intent: Intent

    init(workspaceID: UUID, tabID: UUID, requestID: String, intent: Intent) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.requestID = requestID
        self.intent = intent
    }

    init?(userInfo: [AnyHashable: Any], actionIdentifier: String) {
        guard let workspace = (userInfo["workspaceID"] as? String).flatMap(UUID.init),
              let tab = (userInfo["tabID"] as? String).flatMap(UUID.init)
        else { return nil }
        self.workspaceID = workspace
        self.tabID = tab
        self.requestID = userInfo["requestID"] as? String ?? ""
        switch actionIdentifier {
        case NotificationActionID.approve: self.intent = .approve
        case NotificationActionID.deny: self.intent = .deny
        case NotificationActionID.dismiss: self.intent = .dismiss
        default: self.intent = .open
        }
    }
}

/// Decides what a banner interaction actually does.
///
/// Acting on an agent from a banner means typing into a live TUI, and a
/// banner can outlive the prompt it describes. Every path that would
/// type checks that the tab is *still* blocked on the *same* request —
/// otherwise it degrades to focusing the tab, which is always safe.
enum NotificationRouter {
    enum Outcome: Equatable {
        case focus
        case dismiss
        case send(String)
    }

    static func resolve(
        route: NotificationRoute,
        attention: AgentAttention,
        approve: String?,
        deny: String?
    ) -> Outcome {
        switch route.intent {
        case .open:
            return .focus
        case .dismiss:
            return .dismiss
        case .approve, .deny:
            guard case .blocked(let blocked) = attention else { return .focus }
            guard let live = blocked.requestID, !live.isEmpty,
                  live == route.requestID
            else { return .focus }
            let keystroke = route.intent == .approve ? approve : deny
            guard let keystroke, !keystroke.isEmpty else { return .focus }
            return .send(keystroke)
        }
    }
}
