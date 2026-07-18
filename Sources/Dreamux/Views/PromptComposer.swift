import AppKit
import SwiftUI

/// The window-bottom prompt bar — "Message Claude…" from any page of a
/// project. Sends into the target workspace's composer claude tab (see
/// `WorkspaceSession.reuseOrOpenComposerTab`); the target pill defaults
/// to **Auto** (active workspace, else `main`) and opens a menu to pin a
/// specific workspace. Hideable via the chevron; `ContentView` persists
/// that and shows a slim reopen chip instead.
struct PromptComposer: View {
    @Binding var text: String
    /// Explicit target workspace id; nil is Auto.
    @Binding var targetID: UUID?
    let workspaces: [Workspace]
    let onSend: () -> Void
    let onHide: () -> Void

    @FocusState private var focused: Bool
    @State private var hideHovered = false
    /// Local keyDown monitor rewriting Shift+Return into Option+Return
    /// while the field is focused — the field's stock ⌥↩ path inserts a
    /// line break at the cursor, so Shift+↩ gets newline semantics
    /// without replacing the field with a custom NSTextView.
    @State private var shiftReturnMonitor: Any?

    private var targetLabel: String {
        guard let targetID,
              let workspace = workspaces.first(where: { $0.id == targetID })
        else { return "Auto" }
        return workspace.name
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                TextField("Message Claude…", text: $text, axis: .vertical)
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

    /// Target selector: Auto (default) or a pinned workspace.
    private var targetPill: some View {
        Menu {
            Button {
                targetID = nil
            } label: {
                if targetID == nil {
                    Label("Auto", systemImage: "checkmark")
                } else {
                    Text("Auto")
                }
            }
            if !workspaces.isEmpty {
                Divider()
                ForEach(workspaces) { workspace in
                    Button {
                        targetID = workspace.id
                    } label: {
                        if targetID == workspace.id {
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
                Text(targetLabel)
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
        .help("Where the prompt goes — Auto targets the active workspace (or main)")
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
