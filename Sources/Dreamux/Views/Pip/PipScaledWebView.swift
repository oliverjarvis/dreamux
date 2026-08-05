import AppKit
import SwiftUI
import WebKit

/// A pipped browser tab, rendered like a stream: the page's real desktop
/// output, uniformly shrunk, with no browser chrome over it.
///
/// The scaling is AppKit's `frame`-vs-`bounds` transform, not
/// `WKWebView.pageZoom` and not a `CALayer` transform:
///
/// - `pageZoom` tells the page it is small, so it re-runs its responsive
///   breakpoints and re-lays-out. A stream does not reflow.
/// - A `CALayer` transform scales pixels but AppKit does NOT route mouse
///   coordinates through it, so the pip would be look-don't-touch.
/// - A scaled `bounds` does both: the render shrinks uniformly AND every
///   event is mapped through the same transform, so the miniature stays
///   clickable, scrollable and typable.
struct PipScaledWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> PipScaledWebHost {
        let host = PipScaledWebHost(webView: webView)
        // "Always from the top": a pip is a view of the site, so it opens
        // at the top however far the tab had been scrolled. This is the
        // one moment it can be done — the web view is shared with the
        // tab, so scrolling later is the user's, not ours to override.
        host.scrollToTop()
        return host
    }

    func updateNSView(_ nsView: PipScaledWebHost, context: Context) {
        nsView.adopt(webView: webView)
    }

    /// Undo the scaled coordinate space, for when this web view goes back
    /// to a full-size pane. Lives here so the knowledge of what was done
    /// to the view and the knowledge of how to undo it stay together.
    static func resetToNaturalScale(_ webView: WKWebView) {
        // A view whose bounds size matches its frame size has the
        // identity transform, which is what a pane wants.
        webView.setBoundsSize(webView.frame.size)
    }
}

/// Clipping container that owns the scaled coordinate space.
final class PipScaledWebHost: NSView {
    private var webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Re-parent if SwiftUI hands us a different tab's web view.
    func adopt(webView newValue: WKWebView) {
        guard newValue !== webView else { return }
        webView.removeFromSuperview()
        webView = newValue
        addSubview(newValue)
        needsLayout = true
        scrollToTop()
    }

    func scrollToTop() {
        webView.evaluateJavaScript("window.scrollTo(0, 0)")
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }

        // Give ourselves a coordinate space `referenceWidth` across. With
        // the frame unchanged, AppKit derives the shrink transform — and
        // applies its inverse to incoming mouse events for free.
        let layout = PipContentScale.layoutBounds(forPanel: frame.size)
        if bounds.size != layout { setBoundsSize(layout) }

        // The page fills that space exactly, so nothing is letterboxed.
        let target = CGRect(origin: .zero, size: layout)
        if webView.frame != target { webView.frame = target }
    }
}
