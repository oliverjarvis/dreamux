import SwiftUI

/// The presentation decision for an attention state, split out from the
/// view so it can be tested — SwiftUI bodies cannot.
///
/// `working` deliberately draws nothing: the run controls already carry
/// running state, and a dot that is always lit is a dot nobody reads.
enum AttentionGlyph: Equatable {
    case blocked
    case done

    init?(_ attention: AgentAttention) {
        switch attention {
        case .blocked: self = .blocked
        case .done: self = .done
        case .working, .none: return nil
        }
    }

    var isFilled: Bool { self == .blocked }

    var accessibilityLabel: String {
        switch self {
        case .blocked: return "Agent needs your attention"
        case .done: return "Agent finished"
        }
    }

    var color: Color {
        switch self {
        case .blocked: return .orange
        case .done: return .secondary
        }
    }
}

/// A 7pt dot: filled when the agent is blocked on you, hollow when it
/// merely finished. 7 rather than the old 5 because CLAUDE.md is right
/// that hierarchy comes from colour and alignment, not from shrinking
/// things past legibility.
struct AttentionDot: View {
    let glyph: AttentionGlyph

    var body: some View {
        Group {
            if glyph.isFilled {
                Circle().fill(glyph.color)
            } else {
                Circle().strokeBorder(glyph.color, lineWidth: 1.5)
            }
        }
        .frame(width: 7, height: 7)
        .accessibilityLabel(glyph.accessibilityLabel)
    }
}
