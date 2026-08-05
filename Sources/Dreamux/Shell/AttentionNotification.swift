import Foundation

enum NotificationCategoryID {
    static let blocked = "dreamux.blocked"
    static let blockedPermission = "dreamux.blocked.permission"
    static let done = "dreamux.done"
}

enum NotificationActionID {
    static let open = "dreamux.action.open"
    static let dismiss = "dreamux.action.dismiss"
    static let approve = "dreamux.action.approve"
    static let deny = "dreamux.action.deny"
}

/// Everything a banner is, decided without touching
/// `UNUserNotificationCenter` — so all of it is testable. The manager's
/// only remaining job is to translate this into a `UNNotificationRequest`
/// and hand it over.
struct AttentionNotification: Equatable {
    enum Urgency: Equatable { case timeSensitive, active }

    let identifier: String
    let threadIdentifier: String
    let categoryIdentifier: String
    let title: String
    let subtitle: String
    let body: String
    let urgency: Urgency
    let userInfo: [String: String]

    static func make(
        workspaceName: String,
        workspaceID: UUID,
        tabID: UUID,
        tabTitle: String,
        harnessDisplayName: String,
        attention: AgentAttention,
        hasVerifiedPermissionRecipe: Bool
    ) -> AttentionNotification? {
        let category: String
        let urgency: Urgency
        let body: String
        var requestID = ""

        switch attention {
        case .none, .working:
            // Nothing is waiting on the user. Never interrupt for this.
            return nil

        case .done(let message):
            category = NotificationCategoryID.done
            urgency = .active
            body = message ?? "Finished"

        case .blocked(let blocked):
            urgency = .timeSensitive
            body = blocked.message ?? Self.fallbackBody(for: blocked.reason)
            requestID = blocked.requestID ?? ""
            // Approve/Deny needs BOTH a verified keystroke recipe and a
            // request id to check staleness against. Without either, the
            // banner can only offer to take you there.
            let actionable = blocked.reason == .permission
                && hasVerifiedPermissionRecipe
                && !requestID.isEmpty
            category = actionable
                ? NotificationCategoryID.blockedPermission
                : NotificationCategoryID.blocked
        }

        let trimmedTab = tabTitle.trimmingCharacters(in: .whitespaces)
        return AttentionNotification(
            // One identifier per tab: posting again replaces the live
            // banner instead of stacking a second one beside it.
            identifier: "dreamux.attention.\(tabID.uuidString)",
            // macOS groups by thread, so a workspace's banners collapse
            // together instead of forming a flat pile.
            threadIdentifier: workspaceID.uuidString,
            categoryIdentifier: category,
            title: workspaceName,
            subtitle: "\(harnessDisplayName) · \(trimmedTab.isEmpty ? "shell" : trimmedTab)",
            body: body,
            urgency: urgency,
            userInfo: [
                "workspaceID": workspaceID.uuidString,
                "tabID": tabID.uuidString,
                "requestID": requestID,
                "harness": harnessDisplayName,
            ]
        )
    }

    private static func fallbackBody(for reason: Blocked.Reason) -> String {
        switch reason {
        case .permission: return "Waiting for a permission decision"
        case .question: return "Waiting for your input"
        case .elicitation: return "A tool is asking for input"
        case .subagentInput: return "A subagent needs your input"
        }
    }
}
