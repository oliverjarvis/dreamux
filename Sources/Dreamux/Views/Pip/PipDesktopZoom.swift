import SwiftUI

/// Page zoom a pipped web view should adopt, or nil when it is rendering
/// at its natural size (every pane in the main window, and every pip
/// whose content isn't a browser tab).
///
/// Delivered by environment rather than a parameter because the view that
/// must act on it — `WebViewRepresentable` — sits several layers below
/// `PipContentView`, inside `TabContentView`'s kind dispatch. A parameter
/// would have to be threaded through every branch of that dispatch and
/// through `WebTabView`, teaching both about pips; an environment value
/// leaves them both unchanged except for the one view that reads it.
private struct PipDesktopZoomKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var pipDesktopZoom: CGFloat? {
        get { self[PipDesktopZoomKey.self] }
        set { self[PipDesktopZoomKey.self] = newValue }
    }
}
