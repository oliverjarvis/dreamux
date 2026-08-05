import Foundation

/// When pips are on screen. One rule, isolated from the notification
/// plumbing that feeds it: pips follow their project window into and out
/// of hiding, but NOT into the background — floating over other apps is
/// the entire point.
enum PipVisibilityPolicy {
    static func shouldShow(windowMiniaturized: Bool, appHidden: Bool) -> Bool {
        !windowMiniaturized && !appHidden
    }
}
