import Foundation

/// What a tab's occupant wants from the user, rendered as a dot on the
/// tab chip. Bonsplit assigns no meaning beyond "draw this dot" — the
/// host app decides when each case applies.
public enum TabAttention: String, Codable, Hashable, Sendable {
    case none
    case working
    case done
    case blocked
}
