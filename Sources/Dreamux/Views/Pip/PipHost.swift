import AppKit
import SwiftUI

/// Makes the set of live pip panels match `PipController.items`.
///
/// A zero-size representable rather than a free-standing manager because
/// the panels' SwiftUI content is built by a closure defined inside
/// `ContentView`: it captures `overviewDependencies` (reassembled on
/// every render, so a pipped Overview's Run controls and gate actions
/// stay wired) and `sidebarMode` (so reveal can change what the window
/// shows). Refreshing each panel's `rootView` on every update pass keeps
/// those captures current.
struct PipHost: NSViewRepresentable {
    /// Read in `ContentView`'s body, not in `updateNSView` — that is what
    /// makes SwiftUI re-render this representable when a pip opens or
    /// closes.
    let items: [PipItem]
    let pips: PipController
    /// `(item, frameProvider, dragHandler) -> content`.
    let makeContent: (PipItem, @escaping () -> CGRect, @escaping (CGPoint) -> Void) -> AnyView

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.observe(hostView: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.sync(items: items, makeContent: makeContent, hostView: nsView)
    }

    /// Fires when this `ContentView` goes away — the window closing, or
    /// the window switching project (`ProjectWindowContents` is
    /// `.id(project.id)`-keyed, so a switch rebuilds this whole subtree).
    /// Both cases close the panels; the tabs behind them keep running.
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.tearDown() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(pips: pips) }

    @MainActor
    final class Coordinator {
        private let pips: PipController
        private var panels: [UUID: PipPanel] = [:]
        private var observers: [NSObjectProtocol] = []
        private weak var hostWindow: NSWindow?
        private var appHidden = false

        init(pips: PipController) { self.pips = pips }

        /// The posting window's identity, as a `Sendable` value that can
        /// cross into a main-actor closure (a `Notification` cannot).
        /// `nonisolated` so it runs in the observer's own context — a
        /// nested func would otherwise inherit the class's `@MainActor`.
        private nonisolated static func senderIdentity(
            of note: Notification
        ) -> ObjectIdentifier? {
            (note.object as? NSWindow).map(ObjectIdentifier.init)
        }

        /// Is `identity` this host's own project window? Miniaturize
        /// notifications arrive for every window in the app, including
        /// other project windows' pips.
        private func isHostWindow(_ identity: ObjectIdentifier?) -> Bool {
            guard let identity, let hostWindow else { return false }
            return ObjectIdentifier(hostWindow) == identity
        }

        /// Watch the two events that hide pips, plus screen changes.
        func observe(hostView: NSView) {
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSApplication.didHideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.appHidden = true; self?.applyVisibility() }
            })
            observers.append(center.addObserver(
                forName: NSApplication.didUnhideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.appHidden = false; self?.applyVisibility() }
            })
            observers.append(center.addObserver(
                forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main
            ) { [weak self] note in
                // `Notification` is not `Sendable`, so the sender is
                // reduced to an `ObjectIdentifier` — which is — before
                // crossing into the main-actor closure. The identity
                // comparison it feeds is unchanged.
                let sender = Self.senderIdentity(of: note)
                MainActor.assumeIsolated {
                    guard let self, self.isHostWindow(sender) else { return }
                    self.applyVisibility()
                }
            })
            observers.append(center.addObserver(
                forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main
            ) { [weak self] note in
                let sender = Self.senderIdentity(of: note)
                MainActor.assumeIsolated {
                    guard let self, self.isHostWindow(sender) else { return }
                    self.applyVisibility()
                }
            })
            observers.append(center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reclampOntoScreens() }
            })
        }

        func sync(
            items: [PipItem],
            makeContent: (PipItem, @escaping () -> CGRect, @escaping (CGPoint) -> Void) -> AnyView,
            hostView: NSView
        ) {
            hostWindow = hostView.window

            // Gone from the registry -> panel goes away.
            let live = Set(items.map(\.id))
            for (id, panel) in panels where !live.contains(id) {
                panel.orderOut(nil)
                PipPanelRegistry.shared.forget(id)
                panels.removeValue(forKey: id)
            }

            for item in items {
                let target = item.target
                let frameProvider: () -> CGRect = { [weak self] in
                    self?.panels[item.id]?.frame ?? item.frame
                }
                let dragHandler: (CGPoint) -> Void = { [weak self] origin in
                    self?.drag(id: item.id, target: target, to: origin)
                }
                let content = makeContent(item, frameProvider, dragHandler)

                if let panel = panels[item.id] {
                    (panel.contentView as? NSHostingView<AnyView>)?.rootView = content
                    // The registry is authoritative for placement (Tidy
                    // rewrites frames); the panel is authoritative during
                    // a live drag, which writes back through `drag`.
                    if panel.frame != item.frame {
                        panel.setFrame(item.frame, display: true)
                    }
                } else {
                    let panel = PipPanel(frame: item.frame)
                    panel.contentView = NSHostingView(rootView: content)
                    panels[item.id] = panel
                    if PipVisibilityPolicy.shouldShow(
                        windowMiniaturized: hostWindow?.isMiniaturized ?? false,
                        appHidden: appHidden
                    ) {
                        panel.orderFront(nil)
                        PipPanelRegistry.shared.record(item.id, isVisible: true)
                    }
                }
            }
        }

        /// A drag step: snap against the other pips and the pip's own
        /// screen, move the panel, and record the result.
        private func drag(id: UUID, target: PipTarget, to origin: CGPoint) {
            guard let panel = panels[id] else { return }
            let proposed = CGRect(origin: origin, size: panel.frame.size)
            let neighbours = panels
                .filter { $0.key != id }
                .map(\.value.frame)
            let screen = screen(containing: proposed).visibleFrame
            let snapped = PipLayout.snap(
                proposed: proposed, neighbours: neighbours, screen: screen)
            panel.setFrameOrigin(snapped.origin)
            pips.setFrame(snapped, for: target)
        }

        private func applyVisibility() {
            let show = PipVisibilityPolicy.shouldShow(
                windowMiniaturized: hostWindow?.isMiniaturized ?? false,
                appHidden: appHidden
            )
            for (id, panel) in panels {
                if show { panel.orderFront(nil) } else { panel.orderOut(nil) }
                PipPanelRegistry.shared.record(id, isVisible: show)
            }
        }

        /// A display was unplugged or resized — pull every pip back onto
        /// a real screen so none of them strands itself out of reach.
        private func reclampOntoScreens() {
            for item in pips.items {
                guard let panel = panels[item.id] else { continue }
                let visible = screen(containing: panel.frame).visibleFrame
                let clamped = PipLayout.clamped(panel.frame, into: visible)
                panel.setFrame(clamped, display: true)
                pips.setFrame(clamped, for: item.target)
            }
        }

        /// The screen holding a frame's centre, falling back to the main
        /// screen and finally to a unit rect so this never returns nil.
        private func screen(containing frame: CGRect) -> NSScreen {
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            return NSScreen.screens.first { $0.frame.contains(centre) }
                ?? NSScreen.main
                ?? NSScreen.screens[0]
        }

        /// Close every panel AND empty the registry. Emptying matters:
        /// without it a switched-away project keeps pip glyphs on its
        /// chips and placeholder panes for panels that no longer exist.
        func tearDown() {
            for (id, panel) in panels {
                panel.orderOut(nil)
                PipPanelRegistry.shared.forget(id)
            }
            panels.removeAll()
            pips.closeAll()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }
    }
}
