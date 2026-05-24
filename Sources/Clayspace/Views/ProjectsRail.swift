import SwiftUI
import AppKit

/// Outermost project-switcher sidebar. Lists every project in the user's
/// ProjectStore and lets the user:
///   • click a row to swap the current window to that project,
///   • drag a row out of the window to spawn a new window for it,
///   • right-click a row for the same "Open in New Window" action.
struct ProjectsRail: View {
    let projects: ProjectStore
    let currentProjectID: UUID
    let onSelect: (UUID) -> Void

    @Environment(\.openWindow) private var openWindow

    static let width: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Projects")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(projects.projects) { project in
                        ProjectRow(
                            project: project,
                            isActive: project.id == currentProjectID,
                            onClick: { onSelect(project.id) },
                            onOpenInNewWindow: { openInNewWindow(project.id) }
                        )
                        .frame(height: 28)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .onAppear { projects.refresh() }
    }

    /// Snapshot the existing project-window list before asking SwiftUI to
    /// open a window, then bring whichever NSWindow appears afterwards to
    /// the front. SwiftUI's `openWindow(value:)` dedupes by binding value
    /// so opening the *current* window's project just brings it forward;
    /// opening any other project creates a fresh window, but in our
    /// testing that window sometimes ends up behind the existing one —
    /// the explicit activate + makeKeyAndOrderFront fixes that.
    private func openInNewWindow(_ id: UUID) {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        openWindow(id: "project", value: id)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let after = NSApp.windows
            if let newWindow = after.first(where: { !before.contains(ObjectIdentifier($0)) }) {
                newWindow.makeKeyAndOrderFront(nil)
            } else {
                NSApp.keyWindow?.orderFront(nil)
            }
        }
    }
}

// MARK: - AppKit-backed row

/// Renders each project row in AppKit so we can capture mouse-drag events
/// to start a native NSDraggingSession. The drag carries the project's
/// UUID as a private pasteboard item (no other app accepts that type),
/// and on session end we check whether the drop happened outside our
/// window — that's the signal to pop the project into a fresh window.
private struct ProjectRow: NSViewRepresentable {
    let project: Project
    let isActive: Bool
    let onClick: () -> Void
    let onOpenInNewWindow: () -> Void

    func makeNSView(context: Context) -> ProjectRowView {
        let view = ProjectRowView()
        view.configure(
            project: project,
            isActive: isActive,
            onClick: onClick,
            onOpenInNewWindow: onOpenInNewWindow
        )
        return view
    }

    func updateNSView(_ nsView: ProjectRowView, context: Context) {
        nsView.configure(
            project: project,
            isActive: isActive,
            onClick: onClick,
            onOpenInNewWindow: onOpenInNewWindow
        )
    }
}

/// Private pasteboard type for project-row drags. We use a non-standard
/// UTI so no other app (Finder in particular) accepts the drop — that
/// way the drag session always ends with `operation == []`, which is
/// our cue to tear off into a new window.
private let projectRowPasteboardType = NSPasteboard.PasteboardType("com.clayspace.project-row")

final class ProjectRowView: NSView, NSDraggingSource {
    private var project: Project?
    private var isActive: Bool = false
    private var isHovered: Bool = false
    private var onClick: (() -> Void)?
    private var onOpenInNewWindow: (() -> Void)?

    private var mouseDownPoint: NSPoint?
    private var isDragging: Bool = false
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func configure(
        project: Project,
        isActive: Bool,
        onClick: @escaping () -> Void,
        onOpenInNewWindow: @escaping () -> Void
    ) {
        let changed = self.project?.id != project.id
            || self.project?.name != project.name
            || self.isActive != isActive
        self.project = project
        self.isActive = isActive
        self.onClick = onClick
        self.onOpenInNewWindow = onOpenInNewWindow
        toolTip = project.rootPath.path
        if changed { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let project else { return }
        let tint = NSColor.controlAccentColor

        // Row background
        let rowRect = bounds.insetBy(dx: 2, dy: 1)
        let rowPath = NSBezierPath(roundedRect: rowRect, xRadius: 6, yRadius: 6)
        if isActive {
            tint.withAlphaComponent(0.92).setFill()
            rowPath.fill()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            rowPath.fill()
        }

        // Folder icon (left)
        let iconSize: CGFloat = 14
        let iconRect = NSRect(
            x: 10,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(.init(paletteColors: [isActive ? .white : tint]))
        if let icon = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) {
            icon.draw(in: iconRect)
        }

        // Project name (right of icon)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: isActive ? .semibold : .regular),
            .foregroundColor: isActive ? NSColor.white : NSColor.labelColor,
        ]
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var attrs = textAttrs
        attrs[.paragraphStyle] = paragraph
        let name = NSAttributedString(string: project.name, attributes: attrs)
        let textHeight = name.size().height
        let textRect = NSRect(
            x: iconRect.maxX + 8,
            y: (bounds.height - textHeight) / 2,
            width: bounds.width - iconRect.maxX - 16,
            height: textHeight
        )
        name.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: - Mouse + drag

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !isDragging else { return }
        let current = convert(event.locationInWindow, from: nil)
        if hypot(current.x - start.x, current.y - start.y) >= 4 {
            isDragging = true
            beginDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !isDragging {
            onClick?()
        }
        mouseDownPoint = nil
        isDragging = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard project != nil else { return nil }
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: "Open in New Window",
            action: #selector(handleOpenNewWindow),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let finderItem = NSMenuItem(
            title: "Show in Finder",
            action: #selector(handleShowInFinder),
            keyEquivalent: ""
        )
        finderItem.target = self
        menu.addItem(finderItem)

        return menu
    }

    @objc private func handleOpenNewWindow() {
        onOpenInNewWindow?()
    }

    @objc private func handleShowInFinder() {
        guard let project else { return }
        NSWorkspace.shared.activateFileViewerSelecting([project.rootPath])
    }

    private func beginDrag(with event: NSEvent) {
        guard let project else { return }
        let item = NSPasteboardItem()
        item.setString(project.id.uuidString, forType: projectRowPasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        if let image = snapshotImage() {
            draggingItem.setDraggingFrame(bounds, contents: image)
        } else {
            draggingItem.draggingFrame = bounds
        }
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        // Our drags never have a real drop target — releasing outside the
        // window is the "tear off" signal. Suppress the default slide-back
        // animation so the icon just disappears when the new window opens.
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    private func snapshotImage() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // No destination accepts our pasteboard, so the OS always reports
        // `[]` on drop. We still need a non-empty mask here so the session
        // is actually allowed to start.
        return [.copy, .generic]
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // Treat "dropped with no operation" as a tear-off gesture only
        // when the cursor left our window — otherwise the user just
        // wiggled the mouse inside the rail and we shouldn't pop a new
        // window.
        guard operation == [] else { return }
        guard let window else { return }
        if !window.frame.contains(screenPoint) {
            onOpenInNewWindow?()
        }
    }
}
