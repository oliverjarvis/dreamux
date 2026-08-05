import AppKit
import SwiftUI

/// A pip's only chrome: a slim bar carrying the live title and a ✕. At
/// rest it is invisible and the content runs edge to edge; it fades in on
/// hover. The bar is also the drag handle and the right-click target.
struct PipChromeView: View {
    let title: String
    /// Bring this tab home. NEVER closes the tab — see the plan's global
    /// constraints.
    let onBringBack: () -> Void
    let onBringAllBack: () -> Void
    let onTidy: () -> Void
    /// Double-click: go to this tab in the window.
    let onReveal: () -> Void
    /// Current panel frame, and where to put it while dragging.
    let frame: () -> CGRect
    let onDragTo: (CGPoint) -> Void

    @State private var hovering = false
    @State private var dragStartMouse: CGPoint?
    @State private var dragStartOrigin: CGPoint?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button(action: onBringBack) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Bring this tab back")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .opacity(hovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(dragGesture)
        .onTapGesture(count: 2, perform: onReveal)
        .contextMenu {
            Button("Bring This Tab Back", action: onBringBack)
            Button("Bring All Pips Back", action: onBringAllBack)
            Divider()
            Button("Tidy Pips", action: onTidy)
        }
    }

    /// Absolute-mouse dragging. `value.translation` is measured in a
    /// space that moves with the window this gesture is moving, so it
    /// collapses toward zero as the window catches up;
    /// `NSEvent.mouseLocation` is in screen coordinates and doesn't care.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { _ in
                let mouse = NSEvent.mouseLocation
                if dragStartMouse == nil {
                    dragStartMouse = mouse
                    dragStartOrigin = frame().origin
                }
                guard let startMouse = dragStartMouse,
                      let startOrigin = dragStartOrigin else { return }
                onDragTo(CGPoint(
                    x: startOrigin.x + (mouse.x - startMouse.x),
                    y: startOrigin.y + (mouse.y - startMouse.y)
                ))
            }
            .onEnded { _ in
                dragStartMouse = nil
                dragStartOrigin = nil
            }
    }
}
