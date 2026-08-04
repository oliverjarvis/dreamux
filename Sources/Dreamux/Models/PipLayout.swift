import CoreGraphics
import Foundation

/// Pure geometry for picture-in-picture panels: rectangles in,
/// rectangles out. No windows, no screens, no observation — so every
/// placement rule is unit-testable without a GUI.
///
/// Coordinates are AppKit's screen space: origin bottom-left, y
/// increasing upward. Callers pass an `NSScreen.visibleFrame` as
/// `screen`, so the menu bar and Dock are already excluded.
enum PipLayout {
    /// How close a dragged edge must come to a target edge before it
    /// snaps, in points.
    static let snapThreshold: CGFloat = 12
    /// Gap between tidied pips, between a tidied pip and its screen
    /// edge, and between two pips snapped against each other.
    static let gutter: CGFloat = 12
    static let defaultSize = CGSize(width: 420, height: 280)
    static let minimumSize = CGSize(width: 240, height: 160)
    /// Inset of the very first pip from its screen corner. Larger than
    /// `gutter`: an untidied pip should read as placed, not docked.
    static let screenInset: CGFloat = 24
    /// How far each successive new pip steps up and to the left, so a
    /// second pip can never land exactly on top of the first.
    static let cascadeStep: CGFloat = 28

    /// Where the `index`-th pip opens: bottom-right, inset, cascading
    /// up-and-left. Always clamped onto `screen`, so a long cascade
    /// stacks up at the edge rather than marching off it.
    static func initialFrame(
        index: Int, size: CGSize = defaultSize, screen: CGRect
    ) -> CGRect {
        let step = CGFloat(index) * cascadeStep
        let origin = CGPoint(
            x: screen.maxX - screenInset - size.width - step,
            y: screen.minY + screenInset + step
        )
        return clamped(CGRect(origin: origin, size: size), into: screen)
    }

    /// A dragged frame pulled onto the nearest edge within
    /// `snapThreshold`. Axes are independent: x can snap while y stays
    /// exactly where the mouse put it. Size is never changed.
    static func snap(proposed: CGRect, neighbours: [CGRect], screen: CGRect) -> CGRect {
        var candidatesX: [CGFloat] = [screen.minX, screen.maxX - proposed.width]
        var candidatesY: [CGFloat] = [screen.minY, screen.maxY - proposed.height]
        for neighbour in neighbours {
            candidatesX += [
                neighbour.minX,                              // align left edges
                neighbour.maxX - proposed.width,             // align right edges
                neighbour.maxX + gutter,                     // sit to its right
                neighbour.minX - proposed.width - gutter,    // sit to its left
            ]
            candidatesY += [
                neighbour.minY,                              // align bottoms
                neighbour.maxY - proposed.height,            // align tops
                neighbour.maxY + gutter,                     // sit above it
                neighbour.minY - proposed.height - gutter,   // sit below it
            ]
        }
        return CGRect(
            x: nearest(to: proposed.minX, among: candidatesX),
            y: nearest(to: proposed.minY, among: candidatesY),
            width: proposed.width,
            height: proposed.height
        )
    }

    /// Every pip packed into a column at the corner of `screen` nearest
    /// `centroid`, in the order given, wrapping into further columns
    /// (toward the screen's middle) when one column fills up.
    static func tidy(
        count: Int, size: CGSize = defaultSize, screen: CGRect, centroid: CGPoint
    ) -> [CGRect] {
        guard count > 0 else { return [] }
        let onRight = centroid.x > screen.midX
        let onTop = centroid.y > screen.midY
        let usableHeight = screen.height - 2 * gutter
        // +gutter because N frames need only N−1 inter-frame gutters.
        let perColumn = max(1, Int((usableHeight + gutter) / (size.height + gutter)))

        return (0..<count).map { index in
            let column = CGFloat(index / perColumn)
            let row = CGFloat(index % perColumn)
            let columnStep = column * (size.width + gutter)
            let rowStep = row * (size.height + gutter)

            let x = onRight
                ? screen.maxX - gutter - size.width - columnStep
                : screen.minX + gutter + columnStep
            let y = onTop
                ? screen.maxY - gutter - size.height - rowStep
                : screen.minY + gutter + rowStep

            return clamped(CGRect(x: x, y: y, width: size.width, height: size.height),
                           into: screen)
        }
    }

    /// `frame` shrunk to fit and shifted fully inside `screen`. Used when
    /// a display is disconnected or its resolution changes, so a pip on a
    /// vanished monitor can't strand itself off-screen.
    static func clamped(_ frame: CGRect, into screen: CGRect) -> CGRect {
        let size = CGSize(
            width: min(frame.width, screen.width),
            height: min(frame.height, screen.height)
        )
        let origin = CGPoint(
            x: min(max(frame.minX, screen.minX), screen.maxX - size.width),
            y: min(max(frame.minY, screen.minY), screen.maxY - size.height)
        )
        return CGRect(origin: origin, size: size)
    }

    /// The candidate within `snapThreshold` closest to `value`, or
    /// `value` itself when nothing is close enough.
    private static func nearest(to value: CGFloat, among candidates: [CGFloat]) -> CGFloat {
        let winner = candidates
            .filter { abs($0 - value) <= snapThreshold }
            .min { abs($0 - value) < abs($1 - value) }
        return winner ?? value
    }
}
