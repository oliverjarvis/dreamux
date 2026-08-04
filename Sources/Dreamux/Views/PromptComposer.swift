import AppKit
import SwiftUI

/// Where the bottom prompt bar's text goes. **Idea** is the default and is
/// a different job from the other two: it runs the intake router (the same
/// one ⌘P runs), which reasons about every plan in flight and picks a
/// disposition. `auto`/`workspace` type into one workspace's claude tab.
///
/// Before this existed the bar had a nil-is-Auto `UUID?`, so the two idea
/// boxes in the app looked identical and disagreed: ⌘P routed, the bar
/// didn't.
enum ComposerTarget: Equatable {
    case idea
    case auto
    case workspace(UUID)

    /// The pill's text.
    func label(workspaces: [Workspace]) -> String {
        switch self {
        case .idea: return "Idea"
        case .auto: return "Auto"
        case .workspace(let id):
            // A pinned workspace can be closed out from under the pill.
            return workspaces.first { $0.id == id }?.name ?? "Auto"
        }
    }

    /// The field's placeholder — so the bar says which job it will do.
    func placeholder(workspaces: [Workspace]) -> String {
        switch self {
        case .idea: return "Describe an idea…"
        case .auto: return "Message Claude…"
        case .workspace(let id):
            guard let name = workspaces.first(where: { $0.id == id })?.name else {
                return "Message Claude…"
            }
            return "Message \(name)'s claude…"
        }
    }
}

/// The window-bottom prompt bar. Its target pill picks one of two jobs:
/// **Idea** (the default) fires the intake router — the same path ⌘P takes,
/// which reads a digest of every plan in flight and dispositions the idea
/// against it — while Auto / a named workspace type into that workspace's
/// composer claude tab (see `WorkspaceSession.reuseOrOpenComposerTab`).
/// Hideable via the chevron; `ContentView` persists that and shows a slim
/// reopen chip instead.
struct PromptComposer: View {
    @Binding var text: String
    @Binding var target: ComposerTarget
    let workspaces: [Workspace]
    /// One-line feedback under the bar — set when a delivery was refused so
    /// the text is never silently dropped. Cleared by the next send.
    let note: String?
    let onSend: () -> Void
    let onHide: () -> Void

    @FocusState private var focused: Bool
    @State private var hideHovered = false
    /// Local keyDown monitor rewriting Shift+Return into Option+Return
    /// while the field is focused — the field's stock ⌥↩ path inserts a
    /// line break at the cursor, so Shift+↩ gets newline semantics
    /// without replacing the field with a custom NSTextView.
    @State private var shiftReturnMonitor: Any?

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                TextField(target.placeholder(workspaces: workspaces),
                          text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    // Reserve a roomy three lines even when empty — the
                    // bar should read as a place to write, not a search
                    // field — growing to eight before scrolling.
                    .lineLimit(3...8)
                    .focused($focused)
                    .onSubmit { if canSend { onSend() } }
                Button(action: onHide) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hideHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(hideHovered ? 0.08 : 0)))
                        .scaleEffect(hideHovered ? 1.15 : 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.snappy(duration: 0.15)) { hideHovered = hovering }
                }
                .help("Hide the prompt bar")
            }

            HStack(spacing: 8) {
                targetPill
                Spacer(minLength: 0)
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(canSend ? Color.white : Color.secondary)
                        .frame(width: 26, height: 26)
                        .background(
                            Circle().fill(canSend
                                ? Color.accentColor
                                : Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send to Claude (⌘↩)")
            }

            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            // Inside the content card: the Overview's surface treatment
            // (subtle lift + hairline), not an opaque window fill.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { focused = true }
        .onAppear { installShiftReturnMonitor() }
        .onDisappear {
            if let shiftReturnMonitor { NSEvent.removeMonitor(shiftReturnMonitor) }
            shiftReturnMonitor = nil
        }
    }

    private func installShiftReturnMonitor() {
        guard shiftReturnMonitor == nil else { return }
        shiftReturnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard focused,
                  event.window?.isKeyWindow == true,
                  event.keyCode == 36,
                  event.modifierFlags.contains(.shift),
                  !event.modifierFlags.contains(.command)
            else { return event }
            return NSEvent.keyEvent(
                with: .keyDown,
                location: event.locationInWindow,
                modifierFlags: .option,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: "\n",
                charactersIgnoringModifiers: "\n",
                isARepeat: false,
                keyCode: 36) ?? event
        }
    }

    /// Target selector: Idea (default), Auto, or a pinned workspace.
    private var targetPill: some View {
        Menu {
            Button {
                target = .idea
            } label: {
                if target == .idea {
                    Label("Idea", systemImage: "checkmark")
                } else {
                    Text("Idea")
                }
            }
            Divider()
            Button {
                target = .auto
            } label: {
                if target == .auto {
                    Label("Auto", systemImage: "checkmark")
                } else {
                    Text("Auto")
                }
            }
            if !workspaces.isEmpty {
                Divider()
                ForEach(workspaces) { workspace in
                    Button {
                        target = .workspace(workspace.id)
                    } label: {
                        if target == .workspace(workspace.id) {
                            Label(workspace.name, systemImage: "checkmark")
                        } else {
                            Text(workspace.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text(target.label(workspaces: workspaces))
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("What the bar does — Idea routes a new idea; Auto messages the active workspace's claude")
    }
}

/// The collapsed composer's reopen affordance — a small trailing chip.
struct PromptComposerReopenChip: View {
    let onShow: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: onShow) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(width: isHovered ? 36 : 28, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(isHovered ? 0.1 : 0.05)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.snappy(duration: 0.15)) { isHovered = hovering }
            }
            .help("Show the prompt bar")
        }
    }
}
