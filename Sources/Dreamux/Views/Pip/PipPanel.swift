import AppKit

/// The settings that make a floating pip behave like one. Pulled out of
/// `PipPanel` as plain constants so they can be asserted without a
/// window server — three of the four are invisible when wrong and only
/// show up as "my pips keep disappearing".
enum PipPanelConfiguration {
    static let styleMask: NSWindow.StyleMask =
        [.titled, .closable, .resizable, .fullSizeContentView]
    static let level: NSWindow.Level = .floating
    static let collectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary]
    /// `NSPanel` defaults this to TRUE. Left alone, every pip vanishes
    /// the instant Dreamux stops being the active app.
    static let hidesOnDeactivate = false

    static func apply(to panel: NSPanel) {
        panel.level = level
        panel.collectionBehavior = collectionBehavior
        panel.hidesOnDeactivate = hidesOnDeactivate
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = PipLayout.minimumSize
    }
}

/// One pip's window. An `NSPanel` rather than an `NSWindow` for two
/// reasons: panels are the right class for floating utility windows, and
/// `E2ECommands.resolveWindow` already filters `!($0 is NSPanel)`, so
/// pips can't hijack the automation harness's window resolution.
///
/// Dragging is NOT `isMovableByWindowBackground`: AppKit's own drag can't
/// be intercepted mid-flight, and magnetism has to happen *during* the
/// drag. `PipChromeView` runs the drag and `PipHost` snaps it.
final class PipPanel: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: PipPanelConfiguration.styleMask,
            backing: .buffered,
            defer: false
        )
        PipPanelConfiguration.apply(to: self)
    }

    /// A titled panel is key-capable by default; spelled out because a
    /// pipped terminal receiving keystrokes depends on it.
    override var canBecomeKey: Bool { true }
}
