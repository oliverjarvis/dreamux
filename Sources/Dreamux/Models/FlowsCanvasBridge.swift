import Foundation

/// The pure half of the Flows canvas bridge: parsing and validation of
/// canvas→native `{id, method, params}` messages, mirroring
/// `AppletBridgeCore`. No IO, no WebKit — `FlowsCanvasSession` drives this
/// against live state. Unknown or malformed messages return nil; the session
/// logs once and applies nothing. Never traps.
enum FlowsCanvasBridge {

    struct Position: Equatable, Sendable {
        let id: String
        let x: Double
        let y: Double
    }

    struct Viewport: Equatable, Sendable {
        let x: Double
        let y: Double
        let zoom: Double
    }

    enum Message: Equatable, Sendable {
        /// The canvas has mounted: flush the queued snapshot, then theme
        /// and saved layout.
        case ready
        /// `nodeID == nil` means the lane box itself is selected.
        case selectNode(laneID: String, nodeID: String?)
        case setLaneExpanded(laneID: String, expanded: Bool)
        /// `laneID == nil` means these are lane-box positions.
        case saveNodePositions(laneID: String?, positions: [Position])
        case saveViewport(Viewport)
        case jsError(message: String)
    }

    static let knownMethods: Set<String> = [
        "ready", "selectNode", "setLaneExpanded",
        "saveNodePositions", "saveViewport", "jsError",
    ]

    /// Parse one `WKScriptMessage.body` (always a property-list value).
    /// Returns nil for anything that isn't a well-formed known method.
    static func parse(_ body: Any) -> Message? {
        guard let dict = body as? [String: Any],
              let method = dict["method"] as? String,
              knownMethods.contains(method)
        else { return nil }
        let params = dict["params"] as? [String: Any] ?? [:]

        switch method {
        case "ready":
            return .ready

        case "selectNode":
            guard let laneID = params["laneID"] as? String else { return nil }
            return .selectNode(laneID: laneID, nodeID: params["nodeID"] as? String)

        case "setLaneExpanded":
            guard let laneID = params["laneID"] as? String,
                  let expanded = params["expanded"] as? Bool
            else { return nil }
            return .setLaneExpanded(laneID: laneID, expanded: expanded)

        case "saveNodePositions":
            guard let raw = params["positions"] as? [[String: Any]] else { return nil }
            var positions: [Position] = []
            positions.reserveCapacity(raw.count)
            for entry in raw {
                guard let id = entry["id"] as? String,
                      let x = finite(entry["x"]), let y = finite(entry["y"])
                else { return nil }
                positions.append(Position(id: id, x: x, y: y))
            }
            return .saveNodePositions(laneID: params["laneID"] as? String, positions: positions)

        case "saveViewport":
            guard let x = finite(params["x"]), let y = finite(params["y"]),
                  let zoom = finite(params["zoom"])
            else { return nil }
            return .saveViewport(Viewport(x: x, y: y, zoom: zoom))

        case "jsError":
            guard let message = params["message"] as? String else { return nil }
            return .jsError(message: message)

        default:
            return nil
        }
    }

    /// A finite `Double` from a plist number, or nil. NaN/±∞ are rejected
    /// rather than clamped: a poisoned coordinate written to
    /// `flows-canvas.json` would strand a node off-canvas on every launch.
    private static func finite(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        // Booleans bridge to NSNumber too; a Bool coordinate is malformed.
        guard !(value is Bool) else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}
