import Foundation
import Observation

/// Cross-window launch intents for the Applet Studio window. Callers that
/// can't reach the studio's view state (the projects rail's add row, the
/// ⇧⌘L menu item, the ⌘K palette) park an intent here and open the
/// window; AppStudioView consumes-and-clears it — the same idiom as
/// E2EBridge's pending* fields. A singleton is enough: there is exactly
/// one Applet Studio window.
@MainActor
@Observable
final class AppStudioIntents {
    static let shared = AppStudioIntents()
    var pendingNewApplet = false

    /// True exactly once per parked intent — reading clears it.
    func consumePendingNewApplet() -> Bool {
        guard pendingNewApplet else { return false }
        pendingNewApplet = false
        return true
    }
}
