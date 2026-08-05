import CoreGraphics
import Foundation

/// Geometry for rendering a pipped web page as a uniform miniature of its
/// desktop self. Pure arithmetic, no WebKit — so the rule is testable.
///
/// This deliberately does NOT use `WKWebView.pageZoom`. Zoom changes the
/// viewport the page is told it has, so the page re-runs its responsive
/// breakpoints and *re-lays-out* — a pipped YouTube came back with the
/// mini-guide sidebar and body text that never shrank with it. A stream
/// does not reflow, and neither should this.
///
/// Instead the web view is laid out at `referenceWidth` and drawn scaled,
/// via AppKit's `frame`-vs-`bounds` transform. That scales rendering AND
/// maps mouse coordinates through the same transform, so a shrunk pip
/// stays clickable without hand-transforming events — which a raw
/// `CALayer` transform would have required.
enum PipContentScale {
    /// The width a pipped page is laid out at, whatever the panel's size.
    static let referenceWidth: CGFloat = 1920

    /// Below this, shrinking stops: the render becomes a smear and WebKit
    /// still pays to lay out and paint every element.
    static let minimumScale: CGFloat = 0.15

    /// How much the reference-width render is shrunk to fit a panel
    /// `width` points wide. Never above 1 — a pip shows a page small or
    /// true-size, never magnified.
    static func scale(forPanelWidth width: CGFloat,
                      referenceWidth: CGFloat = referenceWidth) -> CGFloat {
        // A zero-width panel is one real layout pass on a freshly opened
        // panel, before SwiftUI has measured it. Render unscaled rather
        // than dividing by nothing.
        guard width > 0, referenceWidth > 0, width < referenceWidth else { return 1 }
        return max(minimumScale, width / referenceWidth)
    }

    /// The coordinate space to lay the page out in so that, once scaled
    /// down, it fills `panel` exactly.
    ///
    /// Width is always `referenceWidth`; height follows the *panel's*
    /// aspect rather than a fixed 1080, so a tall pip shows more page
    /// instead of letterboxing a 16:9 render into it.
    static func layoutBounds(forPanel panel: CGSize,
                             referenceWidth: CGFloat = referenceWidth) -> CGSize {
        let scale = scale(forPanelWidth: panel.width, referenceWidth: referenceWidth)
        guard scale < 1, scale > 0 else { return panel }
        return CGSize(width: panel.width / scale, height: panel.height / scale)
    }
}
