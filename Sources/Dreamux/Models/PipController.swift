import Bonsplit
import CoreGraphics
import Foundation
import Observation

/// What a pip is showing. A tab is identified by its workspace as well as
/// its tab id: tab ids are unique, but every close-cascade and content
/// lookup needs the workspace anyway, and carrying it makes
/// `closeAll(inWorkspace:)` a filter rather than a search.
enum PipTarget: Hashable {
    case tab(workspaceID: UUID, tabID: TabID)
    case applet(id: UUID)
}

/// One open pip.
struct PipItem: Identifiable, Equatable {
    let id: UUID
    let target: PipTarget
    /// Screen frame, in AppKit coordinates. Mutated by dragging,
    /// resizing, and Tidy.
    var frame: CGRect
    /// The tab chip's icon from before it was marked as pipped, put back
    /// on close. Nil for applet pips (there is no chip) and for a chip
    /// that genuinely had no icon.
    let restoreIcon: String?
}

/// The registry of open pips for one project window. Deliberately free of
/// AppKit: it knows *what* is pipped and *where*, never *how* a panel is
/// made. `PipHost` turns this state into `NSPanel`s; this type can be
/// exercised entirely in unit tests.
@MainActor
@Observable
final class PipController {
    /// How a pip marks its source tab's chip. Injected rather than
    /// reached for, so the registry carries no dependency on
    /// `WorkspaceStore` and tests can pass a recording double.
    /// `PipChipMarker.make(store:)` builds the real one.
    ///
    /// `@MainActor` because a nested type does NOT inherit its enclosing
    /// type's isolation: without it the non-`Sendable` closures make
    /// `.none` a concurrency error under Swift 6.
    @MainActor
    struct ChipMarker {
        var icon: (PipTarget) -> String?
        var setIcon: (PipTarget, String?) -> Void

        /// Marks nothing — the default, and what applet-only tests want.
        static let none = ChipMarker(icon: { _ in nil }, setIcon: { _, _ in })
    }

    /// SF Symbol a pipped tab's chip wears until it comes home.
    static let pippedChipIcon = "pip.fill"

    /// Open pips in creation order. Tidy lays them out in this order.
    private(set) var items: [PipItem] = []

    private let chip: ChipMarker

    init(chip: ChipMarker = .none) {
        self.chip = chip
    }

    func isPipped(_ target: PipTarget) -> Bool {
        items.contains { $0.target == target }
    }

    func item(for target: PipTarget) -> PipItem? {
        items.first { $0.target == target }
    }

    /// Open a pip at `frame` (compute it with `PipLayout`). Opening a
    /// target that is already pipped is a no-op that returns the existing
    /// item, so a double-fired menu can't stack two panels on one tab.
    @discardableResult
    func open(_ target: PipTarget, frame: CGRect) -> PipItem {
        if let existing = item(for: target) { return existing }
        let item = PipItem(
            id: UUID(), target: target, frame: frame, restoreIcon: chip.icon(target))
        items.append(item)
        chip.setIcon(target, Self.pippedChipIcon)
        return item
    }

    /// Bring a pip home: drop the item and give the chip its icon back.
    /// This never touches the underlying session — closing a pip must not
    /// be able to end a running agent.
    func close(_ target: PipTarget) {
        guard let index = items.firstIndex(where: { $0.target == target }) else { return }
        let item = items.remove(at: index)
        chip.setIcon(target, item.restoreIcon)
    }

    func closeAll() {
        for target in items.map(\.target) { close(target) }
    }

    func closeAll(inWorkspace workspaceID: UUID) {
        for target in items.map(\.target) {
            if case .tab(let owner, _) = target, owner == workspaceID { close(target) }
        }
    }

    /// Cascade from a tab closing in the window.
    func close(tabID: TabID) {
        for target in items.map(\.target) {
            if case .tab(_, let id) = target, id == tabID { close(target) }
        }
    }

    /// Cascade from an applet being removed from the project.
    func close(appletID: UUID) {
        close(.applet(id: appletID))
    }

    func setFrame(_ frame: CGRect, for target: PipTarget) {
        guard let index = items.firstIndex(where: { $0.target == target }) else { return }
        items[index].frame = frame
    }

    /// Adopt the output of `PipLayout.tidy(count:size:screen:centroid:)`,
    /// positionally. A short list leaves the surplus pips where they are
    /// rather than trapping.
    func applyTidy(_ frames: [CGRect]) {
        for (index, frame) in frames.enumerated() where items.indices.contains(index) {
            items[index].frame = frame
        }
    }

    /// Mean centre of every open pip — the anchor Tidy picks its corner
    /// from, so tidying moves pips to the side of the screen they were
    /// already drifting toward.
    var centroid: CGPoint {
        guard !items.isEmpty else { return .zero }
        let sum = items.reduce(CGPoint.zero) { total, item in
            CGPoint(x: total.x + item.frame.midX, y: total.y + item.frame.midY)
        }
        return CGPoint(x: sum.x / CGFloat(items.count), y: sum.y / CGFloat(items.count))
    }
}
