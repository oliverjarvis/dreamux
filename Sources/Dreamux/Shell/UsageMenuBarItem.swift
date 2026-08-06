import AppKit
import Observation

/// The menu bar accessory: a gauge glyph and the worst of the two quota
/// percentages — the number that would actually stop you — with both
/// windows, their reset times, and a way out in the menu behind it.
///
/// Narrow enough for a notched laptop, and unambiguous about which
/// figure is shown, which "icon only" cannot be and "both percentages"
/// pays for in width.
///
/// Dreamux stays a regular windowed app: this is an accessory, so
/// nothing here touches `Info.plist` or `NSApp.setActivationPolicy`.
@MainActor
final class UsageMenuBarItem {
    private let store: UsageStore
    private var item: NSStatusItem?

    init(store: UsageStore) {
        self.store = store
    }

    /// Install (if warranted) and start tracking the store.
    func start() {
        sync()
        observe()
    }

    /// Shown only when the user hasn't hidden it AND a reading exists —
    /// no empty gauge, and no zeroed one.
    static func shouldShow(snapshot: ClaudeUsageSnapshot?, visible: Bool) -> Bool {
        visible && snapshot != nil
    }

    /// The menu's item titles, top to bottom, with the separator
    /// implied before the last one. One tested source for the copy.
    static func menuTitles(_ display: UsageDisplay) -> [String] {
        var titles: [String] = []
        if let row = display.fiveHour { titles.append(line("Session (5h)", row)) }
        if let row = display.sevenDay { titles.append(line("Week (7d)", row)) }
        titles.append(display.ageText)
        titles.append("Hide from menu bar")
        return titles
    }

    private static func line(_ prefix: String, _ row: UsageDisplay.Row) -> String {
        guard let reset = row.resetText else { return "\(prefix)  \(row.percentText)" }
        return "\(prefix)  \(row.percentText) · \(reset)"
    }

    /// The Phosphor gauge as a template image, so macOS tints it for
    /// the active menu bar appearance — the same fill-weight set the
    /// sidebar uses.
    private static let glyph: NSImage? = {
        guard let image = PhosphorIcon.nsImage("gauge-fill") else { return nil }
        image.size = NSSize(width: 15, height: 15)
        image.isTemplate = true
        return image
    }()

    /// Bring the status item in line with the store: install it, tear it
    /// down, or refresh its title and menu.
    private func sync() {
        guard Self.shouldShow(snapshot: store.snapshot, visible: store.menuBarVisible),
              let snapshot = store.snapshot
        else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }

        let statusItem = item
            ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item = statusItem

        let display = UsageDisplay.make(snapshot: snapshot, at: store.now)
        if let button = statusItem.button {
            button.image = Self.glyph
            button.imagePosition = .imageLeading
            button.title = display.worstText.map { " " + $0 } ?? ""
            button.toolTip = "Claude subscription usage"
        }
        statusItem.menu = menu(display)
    }

    private func menu(_ display: UsageDisplay) -> NSMenu {
        let menu = NSMenu()
        // Everything but the last title is read-only detail; the last
        // one is the action, behind the separator.
        for title in Self.menuTitles(display).dropLast() {
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide from menu bar",
                              action: #selector(hideFromMenuBar), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        return menu
    }

    /// Hidden from here, restored from the sidebar footer's popover —
    /// so it can never be turned off with no way back.
    @objc private func hideFromMenuBar() {
        store.menuBarVisible = false
    }

    /// Track the store outside SwiftUI. `withObservationTracking` fires
    /// once, so the handler re-arms itself.
    private func observe() {
        withObservationTracking {
            _ = store.snapshot
            _ = store.now
            _ = store.menuBarVisible
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.observe()
            }
        }
    }
}
