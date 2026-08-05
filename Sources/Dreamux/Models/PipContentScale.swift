import CoreGraphics
import Foundation

/// How much to shrink desktop-shaped web content so a whole page fits a
/// pip. Pure arithmetic, no WebKit — so the rule is unit-testable.
///
/// The lever this feeds is `WKWebView.pageZoom`, where the CSS viewport a
/// page lays out in is `viewWidth / pageZoom`. Setting zoom to
/// `panelWidth / 1920` therefore makes a 420pt panel report ~1920 CSS px
/// to the page: it renders its full desktop layout, drawn small, instead
/// of collapsing into the narrow/mobile layout a genuinely 420pt-wide
/// browser would trigger.
enum PipContentScale {
    /// The layout width a pipped page is asked to pretend it has.
    static let referenceWidth: CGFloat = 1920

    /// Below this, shrinking stops. Sub-pixel text reads as a smear and
    /// WebKit still pays to lay out and paint every element.
    static let minimumZoom: CGFloat = 0.15

    /// Page zoom for a panel `width` points wide. Never exceeds 1 — a
    /// pip shows a page small or true-size, never magnified.
    static func zoom(forPanelWidth width: CGFloat,
                     referenceWidth: CGFloat = referenceWidth) -> CGFloat {
        // A zero-width panel is one real layout pass on a freshly opened
        // panel, before SwiftUI has measured it. Render unscaled rather
        // than dividing by nothing.
        guard width > 0, referenceWidth > 0, width < referenceWidth else { return 1 }
        return max(minimumZoom, width / referenceWidth)
    }
}
