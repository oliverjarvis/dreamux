// Sources/Dreamux/Views/FlowsCanvasView.swift
import AppKit
import SwiftUI
import WebKit

/// The Flows pane: a native header and inspector around one continuous
/// React Flow canvas. The canvas owns the graph — lane placement, expansion,
/// drag, zoom — and native SwiftUI keeps the header badges, the node
/// inspector, the gate actions (they merge branches and push PRs; they stay
/// native deliberately), the JS error strip and the empty state.
struct FlowsCanvasView: View {
    @ObservedObject var flows: FlowStore
    @Bindable var session: FlowsCanvasSession
    let planLaneInputs: () -> [PlanLaneInput]
    var prStatesByWorkspace: [UUID: PRLaneState] = [:]
    /// Grafts a plan lane's live subagents onto its task nodes before the
    /// lane reaches `FlowsBoard.compose` — a closure (not a stored value)
    /// so it always sees live `FlowStore`/`DocStore` state.
    let graftSubagents: (Flow) -> Flow
    /// The project's plan-dependency DAG, rebuilt each render pass from
    /// live `DocStore` state — it is now what ARRANGES the canvas, not a
    /// separate "This project" panel.
    let projectGraph: () -> ProjectGraph
    let onJumpToTerminal: (UUID) -> Void
    let onOpenTranscript: (String) -> Void
    let gateActions: FlowGateActions

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let inspectorWidth: CGFloat = 280

    private static let elapsedFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    /// One Equatable value so a single `.onChange` drives the push, instead
    /// of mutating session state during `body` evaluation.
    private struct CanvasInput: Equatable {
        let board: FlowsBoard
        let graph: ProjectGraph
    }

    var body: some View {
        let inputs = planLaneInputs()
        let board = FlowsBoard.compose(
            planLanes: PlanFlowBuilder.lanes(from: inputs).map(graftSubagents),
            sessionLanes: flows.flows,
            prStatesByWorkspace: prStatesByWorkspace
        )
        // Which plan lanes may offer "merge & continue", keyed by lane id.
        let mergeActionableLaneIDs = Set(
            inputs.filter(PlanFlowBuilder.isGateMergeActionable)
                .map { "plan-\($0.planPath)" })
        let input = CanvasInput(board: board, graph: projectGraph())

        return VStack(spacing: 0) {
            headerRow(board)
            errorStrip
            Divider()
            HStack(spacing: 0) {
                canvas(isEmpty: board.sections.isEmpty)
                Divider()
                inspector(board: board, mergeActionableLaneIDs: mergeActionableLaneIDs)
                    .frame(width: Self.inspectorWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: input, initial: true) { _, new in
            session.update(board: new.board, projectGraph: new.graph)
        }
        .onChange(of: ThemeKey(colorScheme: colorScheme, reduceMotion: reduceMotion),
                  initial: true) { _, key in
            session.applyTheme(
                vars: FlowsCanvasTheme.variables(
                    accent: .accentColor, colorScheme: key.colorScheme),
                reduceMotion: key.reduceMotion)
        }
    }

    private struct ThemeKey: Equatable {
        let colorScheme: ColorScheme
        let reduceMotion: Bool
    }

    // MARK: - Header

    /// Today's title and badges, with two changes: the badges are clickable
    /// (firing `focusLane` at the first matching lane) and "Tidy up" joins
    /// them in the outlined-pill shape CLAUDE.md requires of header controls.
    private func headerRow(_ board: FlowsBoard) -> some View {
        HStack(spacing: 10) {
            Text("Flows")
                .font(.title3.weight(.semibold))
            Spacer()
            if board.runningCount > 0 {
                badgeButton("\(board.runningCount) running",
                            color: FlowStatusGlyph.color(.running)) {
                    focusFirstLane(in: board) { $0.effectiveStatus == .running }
                }
            }
            if board.needsYouCount > 0 {
                badgeButton("\(board.needsYouCount) needs you",
                            color: FlowStatusGlyph.color(.waiting)) {
                    focusFirstLane(in: board) {
                        $0.effectiveStatus == .waiting || $0.effectiveStatus == .failed
                    }
                }
            }
            tidyUpControl
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func badgeButton(
        _ text: String, color: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Jump to the first matching lane")
    }

    /// The shared header-control shape: outlined pill, cornerRadius 8,
    /// `.secondary.opacity(0.3)` border over a `.primary.opacity(0.04)` fill.
    private var tidyUpControl: some View {
        Button {
            session.tidyUp(laneID: session.selection?.laneID)
        } label: {
            Text("Tidy up")
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1))
        )
        .help(session.selection == nil
              ? "Re-run auto-layout for the whole board"
              : "Re-run auto-layout for the selected lane")
    }

    private func focusFirstLane(in board: FlowsBoard, where match: (FlowsBoard.Lane) -> Bool) {
        for section in board.sections {
            if let lane = section.lanes.first(where: match) {
                session.focusLane(lane.id, expand: true)
                return
            }
        }
    }

    // MARK: - Error strip

    /// Native, orange-tinted, with the last JS message and a Reload button
    /// — the shape `AppletHostView` already uses for `lastJSError`. The
    /// canvas keeps whatever it last rendered.
    @ViewBuilder
    private var errorStrip: some View {
        if let error = session.lastJSError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Reload") { session.reload() }
                    .buttonStyle(.soft)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.08))
        }
    }

    // MARK: - Canvas

    private func canvas(isEmpty: Bool) -> some View {
        ZStack {
            FlowsCanvasWebViewRepresentable(webView: session.webView)
            if isEmpty { emptyState }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Today's copy, as a native overlay when the board has no lanes.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing in flight")
                .font(.headline)
            Text("Run a plan, or open a terminal and start claude — sessions, subagents, and plan runs appear here as live lanes the moment they start.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420, alignment: .leading)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }

    // MARK: - Inspector

    /// Today's `nodeInspector`, unchanged in content, driven by the
    /// bridge-reported `(laneID, nodeID)` selection: it falls back to the
    /// lane summary when a lane box is selected, and to a board summary
    /// when nothing is.
    @ViewBuilder
    private func inspector(
        board: FlowsBoard, mergeActionableLaneIDs: Set<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selection = session.selection, let lane = lane(forID: selection.laneID, in: board) {
                if let nodeID = selection.nodeID,
                   let node = lane.flow.nodes.first(where: { $0.id == nodeID }) {
                    nodeInspector(
                        node, lane: lane,
                        gateMergeActionable: mergeActionableLaneIDs.contains(lane.id))
                } else {
                    laneSummary(lane)
                }
            } else {
                boardSummary(board)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func lane(forID id: String, in board: FlowsBoard) -> FlowsBoard.Lane? {
        for section in board.sections {
            if let match = section.lanes.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    private func boardSummary(_ board: FlowsBoard) -> some View {
        let laneCount = board.sections.reduce(0) { $0 + $1.lanes.count }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Flows")
                .font(.headline)
            Text("\(laneCount) lane\(laneCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Select a lane or a node on the canvas to inspect it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func laneSummary(_ lane: FlowsBoard.Lane) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lane.flow.title)
                .font(.headline)
            if let chip = lane.sessionChip {
                Text(chip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(lane.flow.nodes.count) node\(lane.flow.nodes.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func nodeInspector(
        _ node: FlowNode, lane: FlowsBoard.Lane, gateMergeActionable: Bool
    ) -> some View {
        // Only the fixed "session" node is the lane's own claude session —
        // every other `.agent`-kind node is a spawned subagent, whose own
        // transcript isn't what "open transcript" resolves.
        let isSessionNode = node.id == "session"
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: FlowStatusGlyph.symbol(node.status))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(FlowStatusGlyph.color(node.status))
                Text(node.label)
                    .font(.headline)
                    .lineLimit(1)
            }
            Text(node.status.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let started = node.startedAt {
                if let ended = node.endedAt {
                    Text(Self.elapsedFormatter.string(from: started, to: ended) ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(started, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let lastActivity = node.lastActivity {
                VStack(alignment: .leading, spacing: 4) {
                    Text("last activity")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(lastActivity)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(4)
                }
            }

            if node.kind == .gate, node.status == .waiting,
               let workspaceID = lane.flow.workspaceID {
                GateActionCard(
                    workspaceID: workspaceID,
                    mergeActionable: gateMergeActionable,
                    actions: gateActions,
                    prState: lane.prState)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button("Open transcript") {
                    if let sessionID = lane.flow.sessionID { onOpenTranscript(sessionID) }
                }
                .disabled(!isSessionNode || lane.flow.sessionID == nil)

                Button("Jump to terminal") {
                    if let workspaceID = lane.flow.workspaceID { onJumpToTerminal(workspaceID) }
                }
                .disabled(lane.flow.workspaceID == nil)
            }
        }
    }
}

/// The CSS custom properties Swift pushes into the canvas. Swift stays the
/// source of truth for status colour — the five `FlowStatusGlyph` colours
/// arrive here rather than being re-guessed in the stylesheet.
enum FlowsCanvasTheme {
    static func variables(accent: Color, colorScheme: ColorScheme) -> [String: String] {
        let dark = colorScheme == .dark
        return [
            "--flows-surface": dark ? "#1b1c1f" : "#f7f7f9",
            "--flows-text": dark ? "#f2f2f4" : "#1b1c1f",
            "--flows-text-secondary": dark ? "#a0a2a8" : "#6b6d75",
            "--flows-border": dark ? "rgba(255, 255, 255, 0.14)" : "rgba(0, 0, 0, 0.14)",
            "--flows-accent": css(accent),
            "--flows-status-running": css(FlowStatusGlyph.color(.running)),
            "--flows-status-queued": css(FlowStatusGlyph.color(.queued)),
            "--flows-status-waiting": css(FlowStatusGlyph.color(.waiting)),
            "--flows-status-done": css(FlowStatusGlyph.color(.done)),
            "--flows-status-failed": css(FlowStatusGlyph.color(.failed)),
        ]
    }

    /// `#rrggbb`. Resolved through `NSColor` in sRGB so a semantic colour
    /// (`.secondary`, `.accentColor`) becomes a concrete value the web view
    /// can use. Falls back to a mid grey rather than emitting an invalid
    /// declaration.
    static func css(_ color: Color) -> String {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return "#808080" }
        let red = Int((srgb.redComponent * 255).rounded())
        let green = Int((srgb.greenComponent * 255).rounded())
        let blue = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", red, green, blue)
    }
}

/// Parents the session-owned canvas `WKWebView` — the same 4-line
/// representable shape `AppletHostView`/`WebTabView` use, so one long-lived
/// web view survives every host redraw.
private struct FlowsCanvasWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
