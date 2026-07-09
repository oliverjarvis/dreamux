import Foundation

/// Errors surfaced by the bridge to the applet's JS side (as a rejected
/// promise, see `AppletSession`). Wording matters: `capabilityNotDeclared`'s
/// message is the same one documented in the scaffold's APPLET.md so applet
/// builders see one consistent story, in-editor and at runtime.
enum AppletBridgeError: Error, LocalizedError {
    case unknownMethod(String)
    case capabilityNotDeclared(method: String, capability: AppletCapability)
    case badParams(String)
    case pathEscapesSandbox(String)

    var errorDescription: String? {
        switch self {
        case .unknownMethod(let method):
            return "unknown method \"\(method)\""
        case .capabilityNotDeclared(_, let capability):
            let name = capability.rawValue
            return "\"\(name)\" capability not declared — add \"\(name)\" to requiresCapabilities in manifest.json"
        case .badParams(let detail):
            return "bad params: \(detail)"
        case .pathEscapesSandbox(let path):
            return "\"\(path)\" escapes the applet's sandbox"
        }
    }
}

/// One parsed JS→native request, decoded from a `WKScriptMessage.body`
/// (always a property-list value: `[String: Any]` with `NSNumber`/`String`/
/// `Array`/`Dictionary`/`NSNull` leaves). `@unchecked Sendable`: plist
/// leaves are all value types crossing from the main-thread WebKit
/// callback, same rationale as the `[String: Any]` bodies handled
/// elsewhere in this codebase (e.g. `SignalEmitSocketServer`).
struct BridgeRequest: @unchecked Sendable {
    let id: Int
    let method: String
    let params: [String: Any]

    /// nil unless `body` is a dictionary with an integer `id` and string
    /// `method`; `params` defaults to `[:]` when absent.
    static func parse(_ body: Any) -> BridgeRequest? {
        guard let dict = body as? [String: Any] else { return nil }
        guard let id = dict["id"] as? Int else { return nil }
        guard let method = dict["method"] as? String else { return nil }
        let params = dict["params"] as? [String: Any] ?? [:]
        return BridgeRequest(id: id, method: method, params: params)
    }
}

/// The pure half of the native bridge: request parsing and capability
/// gating. No IO, no WebKit — `AppletSession` drives this against a live
/// `AppletDataStore` / manifest.
enum AppletBridgeCore {
    /// Every method the bridge understands, including the capability-free
    /// `context`. Anything outside this set is `unknownMethod`.
    static let knownMethods: Set<String> = [
        "context", "kv.get", "kv.set", "kv.delete", "kv.list",
        "fs.read", "fs.write", "fs.list", "fs.delete",
        "http.fetch", "shell.exec", "notify",
    ]

    /// The capability a known method needs; nil = always allowed
    /// ("context"). Callers must check `knownMethods` first — this returns
    /// nil for unknown methods too, which `checkAllowed` never reaches.
    static func capability(forMethod method: String) -> AppletCapability? {
        switch method {
        case "kv.get", "kv.set", "kv.delete", "kv.list":
            return .kv
        case "fs.read", "fs.write", "fs.list", "fs.delete":
            return .fs
        case "http.fetch":
            return .http
        case "shell.exec":
            return .shell
        case "notify":
            return .notify
        default:
            return nil
        }
    }

    /// Gate a request before dispatch: unknown methods throw
    /// `unknownMethod`; known methods whose capability isn't in `granted`
    /// throw `capabilityNotDeclared`.
    static func checkAllowed(method: String, granted: Set<AppletCapability>) throws {
        guard knownMethods.contains(method) else {
            throw AppletBridgeError.unknownMethod(method)
        }
        guard let capability = capability(forMethod: method) else {
            return
        }
        guard granted.contains(capability) else {
            throw AppletBridgeError.capabilityNotDeclared(method: method, capability: capability)
        }
    }
}
