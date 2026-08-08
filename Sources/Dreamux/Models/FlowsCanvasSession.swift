import AppKit
import Foundation
import Observation
import WebKit

/// Which node the native inspector is describing. `nodeID == nil` means
/// the lane box itself is selected.
struct FlowsCanvasSelection: Equatable, Sendable {
    let laneID: String
    let nodeID: String?
}

/// Everything live behind the Flows canvas: the long-lived `WKWebView`
/// serving `Sources/Dreamux/Resources/FlowsCanvas` over `dreamux-flows://`,
/// the push discipline that keeps SwiftUI's render cadence out of the web
/// view, the expansion set (capped, LRU) that drives the lazy transcript
/// tail, and the selection the native inspector renders.
///
/// Held per-project by `ProjectSession` — NOT rebuilt per render, the same
/// discipline `AppletSession` uses to keep a `WKWebView` alive across
/// SwiftUI redraws (and the mitigation for web-view startup cost on tab
/// switch: it is created once per project, not per tab activation).
@MainActor
@Observable
final class FlowsCanvasSession {

    /// Each expanded lane holds a lazy tailer; `FlowTailerPool` already
    /// caps agent tailers at 24 per session. Three keeps file descriptors
    /// bounded and the canvas legible.
    static var expansionCap: Int { FlowsCanvasLayoutStore.expansionCap }

    private(set) var snapshot: FlowsCanvasSnapshot?
    /// Kept alongside the snapshot: `setLaneExpanded` needs the lane's
    /// `sessionID`/`sessionCwd` for the tail seam, and the wire model
    /// deliberately does not carry them.
    private(set) var board: FlowsBoard?
    private(set) var expandedLaneIDs: [String] = []
    var selection: FlowsCanvasSelection?
    var lastJSError: String?
    /// Bumped on every real `render` push — the pushes-are-gated invariant
    /// is what the unit tests assert against.
    private(set) var pushCount = 0

    let layout: FlowsCanvasLayoutStore

    @ObservationIgnored private let beginTail: (String, String?) -> Void
    @ObservationIgnored private let endTail: (String) -> Void
    @ObservationIgnored private var isReady = false
    @ObservationIgnored private var lastPushed: FlowsCanvasSnapshot?
    @ObservationIgnored private var queuedSnapshot: FlowsCanvasSnapshot?
    @ObservationIgnored private var lastTheme: (vars: [String: String], reduceMotion: Bool)?
    @ObservationIgnored private var _webView: WKWebView?
    /// Held strongly — `WKWebView.navigationDelegate` is a weak reference,
    /// so nothing else keeps this alive.
    @ObservationIgnored private var navigationPolicy: FlowsCanvasNavigationPolicy?

    init(
        layout: FlowsCanvasLayoutStore,
        beginTail: @escaping (String, String?) -> Void,
        endTail: @escaping (String) -> Void
    ) {
        self.layout = layout
        self.beginTail = beginTail
        self.endTail = endTail
        self.expandedLaneIDs = layout.payload.expandedLaneIDs
    }

    // MARK: - Snapshot push

    /// Recompute and push only on a real change. `FlowsOverviewView` used
    /// to recompose the board on every SwiftUI render pass; forwarding that
    /// cadence into a web view would be a flood.
    func update(board: FlowsBoard, projectGraph: ProjectGraph) {
        self.board = board
        let next = FlowsCanvasSnapshot.make(board: board, projectGraph: projectGraph)
        snapshot = next
        guard next != lastPushed else { return }
        lastPushed = next
        pushCount += 1
        // Pushes before `ready` collapse into ONE queued snapshot.
        guard isReady else {
            queuedSnapshot = next
            return
        }
        dispatch("render", json: next.jsonString())
    }

    // MARK: - Native → canvas commands

    /// Expand (optionally) and zoom-to-fit one lane. A nil `laneID`
    /// collapses whatever is expanded — the `zoomFlow laneID: null` form.
    func focusLane(_ laneID: String?, expand: Bool = true) {
        guard let laneID else {
            for id in expandedLaneIDs { releaseTail(forLaneID: id) }
            expandedLaneIDs = []
            layout.setExpanded([])
            dispatch("focusLane", json: #"{"laneID":null,"expand":false}"#)
            return
        }
        if expand { setExpanded(laneID, true) }
        let escaped = Self.jsonString(laneID)
        dispatch("focusLane", json: #"{"laneID":\#(escaped),"expand":\#(expand)}"#)
    }

    /// Discard saved positions for a lane, or the whole board, and re-run
    /// auto-layout — so auto-layout is a recoverable action, not a lost
    /// capability.
    func tidyUp(laneID: String?) {
        if let laneID {
            layout.clearLane(laneID)
            dispatch("tidyUp", json: #"{"laneID":\#(Self.jsonString(laneID))}"#)
        } else {
            layout.clearAll()
            dispatch("tidyUp", json: "{}")
        }
    }

    /// Swift stays the source of truth for status colour. Called on
    /// appearance, accent and reduce-motion change.
    func applyTheme(vars: [String: String], reduceMotion: Bool) {
        lastTheme = (vars, reduceMotion)
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["vars": vars, "reduceMotion": reduceMotion], options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return }
        dispatch("applyTheme", json: json)
    }

    /// Clears the error strip and re-navigates the existing session web
    /// view. Safe before the web view has ever been created.
    func reload() {
        lastJSError = nil
        isReady = false
        lastPushed = nil
        queuedSnapshot = snapshot
        _webView?.load(URLRequest(url: Self.indexURL))
    }

    /// `window.dreamuxFlows.debugState()` as a JSON string — the e2e
    /// `flowsCanvasState` command's only reach into the canvas.
    func debugStateJSON() async -> String? {
        guard let webView = _webView else { return nil }
        let result = try? await webView.evaluateJavaScript("window.dreamuxFlows.debugState()")
        return result as? String
    }

    // MARK: - Canvas → native

    /// The testable seam. `FlowsCanvasMessageHandler` parses and forwards;
    /// anything malformed never gets this far.
    func handle(_ message: FlowsCanvasBridge.Message) {
        switch message {
        case .ready:
            isReady = true
            if let queued = queuedSnapshot ?? snapshot {
                dispatch("render", json: queued.jsonString())
                queuedSnapshot = nil
            }
            if let lastTheme {
                applyTheme(vars: lastTheme.vars, reduceMotion: lastTheme.reduceMotion)
            }
            restoreLayout()

        case .selectNode(let laneID, let nodeID):
            // The canvas reports an empty laneID for a pane click.
            selection = laneID.isEmpty ? nil : FlowsCanvasSelection(laneID: laneID, nodeID: nodeID)

        case .setLaneExpanded(let laneID, let expanded):
            setExpanded(laneID, expanded)

        case .saveNodePositions(let laneID, let positions):
            let map = Dictionary(
                positions.map { ($0.id, FlowsCanvasLayoutStore.Point(x: $0.x, y: $0.y)) },
                uniquingKeysWith: { _, last in last })
            if let laneID {
                layout.setNodePositions(laneID, map)
            } else {
                layout.setLanePositions(map)
            }

        case .saveViewport(let viewport):
            layout.setViewport(.init(x: viewport.x, y: viewport.y, zoom: viewport.zoom))

        case .jsError(let message):
            lastJSError = message
        }
    }

    // MARK: - Expansion

    /// Expansion is EXPLICIT state, never a side effect of zoom: each
    /// expanded lane subscribes a transcript tail, and zooming past ten
    /// lanes must not open ten tails.
    private func setExpanded(_ laneID: String, _ expanded: Bool) {
        if expanded {
            guard !expandedLaneIDs.contains(laneID) else { return }
            var next = expandedLaneIDs + [laneID]
            while next.count > Self.expansionCap {
                releaseTail(forLaneID: next.removeFirst())
            }
            expandedLaneIDs = next
            beginTail(forLaneID: laneID)
        } else {
            guard expandedLaneIDs.contains(laneID) else { return }
            expandedLaneIDs.removeAll { $0 == laneID }
            releaseTail(forLaneID: laneID)
        }
        layout.setExpanded(expandedLaneIDs)
    }

    /// Sent once after `ready`. Saved expansion is truncated to the cap by
    /// the store, and each surviving entry subscribes its lazy tail exactly
    /// as a click would.
    private func restoreLayout() {
        dispatch("restoreLayout", json: layout.jsonString())
        let saved = layout.payload.expandedLaneIDs
        expandedLaneIDs = []
        for laneID in saved {
            expandedLaneIDs.append(laneID)
            beginTail(forLaneID: laneID)
        }
    }

    private func beginTail(forLaneID laneID: String) {
        guard let lane = lane(forID: laneID), let sessionID = lane.flow.sessionID else { return }
        beginTail(sessionID, lane.flow.sessionCwd)
    }

    private func releaseTail(forLaneID laneID: String) {
        guard let lane = lane(forID: laneID), let sessionID = lane.flow.sessionID else { return }
        endTail(sessionID)
    }

    private func lane(forID id: String) -> FlowsBoard.Lane? {
        guard let board else { return nil }
        for section in board.sections {
            if let match = section.lanes.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    // MARK: - Web view

    private static let indexURL = URL(
        string: "\(BundledAssetSchemeHandler.flowsScheme)://app/index.html")!

    /// Built once, on first access — a first-party renderer, not an applet:
    /// no fs, shell, http or kv bridge methods reach it.
    var webView: WKWebView {
        if let _webView { return _webView }

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(
            BundledAssetSchemeHandler(
                scheme: BundledAssetSchemeHandler.flowsScheme,
                root: BundledAssetSchemeHandler.bundledRoot(named: "FlowsCanvas")),
            forURLScheme: BundledAssetSchemeHandler.flowsScheme
        )
        config.userContentController.add(
            FlowsCanvasMessageHandler(owner: self), name: "dreamuxFlows")

        let view = WKWebView(frame: .zero, configuration: config)
        // Let the canvas paint on the app surface rather than a white sheet
        // flashing through on load.
        view.setValue(false, forKey: "drawsBackground")
        let policy = FlowsCanvasNavigationPolicy(owner: self)
        navigationPolicy = policy
        view.navigationDelegate = policy
        view.isInspectable = true
        view.load(URLRequest(url: Self.indexURL))

        _webView = view
        return view
    }

    private func dispatch(_ method: String, json: String?) {
        guard let json, let webView = _webView else { return }
        webView.evaluateJavaScript("window.dreamuxFlows.\(method)(\(Self.jsonString(json)))")
    }

    /// A JS string literal for `value`, quoted and escaped by
    /// `JSONSerialization` — never hand-rolled escaping.
    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8),
              array.count >= 2
        else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }
}

/// The `WKScriptMessageHandler` half. Holds its owner **weakly**: the
/// retain chain runs `webView` → `configuration` → `userContentController`
/// → this handler, and the owning session owns the `webView` — a strong
/// reference back would close that into a cycle that never deallocates.
final class FlowsCanvasMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var owner: FlowsCanvasSession?

    init(owner: FlowsCanvasSession) {
        self.owner = owner
        super.init()
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WKWebView delivers script messages on the main thread; this
        // asserts that rather than hopping, matching AppletBridge.
        MainActor.assumeIsolated {
            guard let owner else { return }
            guard let parsed = FlowsCanvasBridge.parse(message.body) else {
                // Unknown or malformed: log once, apply nothing, never trap.
                NSLog("[FlowsCanvas] dropped unparsable bridge message")
                return
            }
            owner.handle(parsed)
        }
    }
}

/// Nav lockdown: only `dreamux-flows:` (and `about:`, for the web view's
/// initial blank frame) navigate in place; `http`/`https` hand off to the
/// user's browser; everything else is refused. Load failures and web
/// content process termination set the same error state a `jsError` does,
/// so the native strip's Reload is always the recovery.
final class FlowsCanvasNavigationPolicy: NSObject, WKNavigationDelegate {
    private weak var owner: FlowsCanvasSession?

    init(owner: FlowsCanvasSession) {
        self.owner = owner
        super.init()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme else { return .cancel }
        switch scheme {
        case BundledAssetSchemeHandler.flowsScheme, "about":
            return .allow
        case "http", "https":
            NSWorkspace.shared.open(url)
            return .cancel
        default:
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { owner?.lastJSError = error.localizedDescription }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated { owner?.lastJSError = error.localizedDescription }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            owner?.lastJSError = "The Flows canvas web process stopped. Reload to restart it."
        }
    }
}
