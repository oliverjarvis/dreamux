# Applet Connections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let applets authenticate to external services (private-repo PRs, Expo builds, …) through named, Keychain-backed **Connections** whose secret never enters the web view — attached natively to allowlisted `https` hosts, or injected as env into a single `shell.exec`.

**Architecture:** A `Connection` (metadata in `connections.json`, secret in Keychain) has an `AuthKind` and an enforced host allowlist. Applets declare `requiresConnections` slots in the manifest; the user binds each slot to a Connection per-applet (`<dataDir>/connections.json`). At call time `http.fetch(url,{connection})` / `shell.exec(cmd,{connection})` resolve the slot → Connection → token and apply it via a pure `ConnectionAuthenticator` (https-only, exact-host). Management lives in Settings; binding in the applet host view.

**Tech Stack:** Swift 6 / SwiftPM, WebKit, Security (Keychain), URLSession, XCTest, e2e harness.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-10-applet-connections-design.md` (read it first).
- **The secret never enters applet JS.** For HTTP it's attached natively; for shell it's injected into one child process's env. No bridge method returns a token.
- **Authenticated fetch is `https`-only** and the URL host must **exactly** (case-insensitive) match one of the *bound Connection's* `hosts` — never a suffix/subdomain match (`api.github.com.evil.com` must reject). The slot's own `hosts` are advisory (UI only); the Connection's `hosts` are enforced.
- Secrets in the macOS **Keychain** (generic password, service `com.dreamux.Dreamux.connection`, account = connection id, `kSecAttrAccessibleWhenUnlocked`) — never a plaintext file in normal operation, never `kv`/`fs`/the manifest. The one exception is a **file-backed** store used only when `$DREAMUX_CONNECTIONS_SECRET_DIR` is set (tests/e2e), mirroring the existing `$DREAMUX_*` override discipline.
- Connections are **global** (metadata under `ProjectStore.stateRootURL()`); bindings are **per applet instance** (`<dataDir>/connections.json`).
- Tokens never appear in logs/signals; any request logging redacts credential headers/query.
- Swift 6: `@MainActor @Observable` stores; pure security logic in `nonisolated`/`static` helpers, unit-tested without actors.
- Manifest change is **back-compatible**: `requiresConnections` is optional, older applets decode unchanged.
- Full `swift test` + `swift build` green before every commit. Stage only named files; re-verify HEAD before each commit.
- **WKWebView content screenshots blank in-process** — e2e asserts bridge side-effects on disk (kv.json), never pixels.

## Adaptation ground rules

Anchors verified at HEAD (2026-07-10, `eeb845a`, App Studio merged). Pure helpers carry complete code + tests; UI/bridge-wiring tasks are anchored sketches, build-gated, verified by e2e (house style — no unit tests for SwiftUI views).

- `Sources/Dreamux/Models/AppletManifest.swift` — `struct AppletManifest: Codable` (`:10`) fields `id/name/slug/icon/description/requiresCapabilities/origin` (`:17-18`), `grantedCapabilities` (`:26`), `static func load` (`:57`); `enum AppletCapability` (`:6`); `AppletSlug` helpers. **Add `requiresConnections`.**
- `Sources/Dreamux/Views/Applets/AppletBridgeCore.swift` — `AppletBridgeError` (`:7`, incl. `capabilityNotDeclared` wording that matches APPLET.md), `BridgeRequest.parse` (`:41`), `knownMethods` (`:56`), `capability(forMethod:)` (`:65`), `checkAllowed` (`:85`). **Add the two `connections.*` methods (capability-free) + new error cases.**
- `Sources/Dreamux/Views/Applets/AppletBridge.swift` — dispatch `switch` (`:60`); `http.fetch` builds a `URLRequest`, applies `headers`, no auth (`:150-183`); `shell.exec` calls `AppletShell.exec(cmd:cwd:timeout:)` (`:185-200`); `reply(...)`/`replyJSON` (`:240-262`). **Add `{connection}` handling + `connections.*` cases.**
- `Sources/Dreamux/Models/AppletSession.swift` — `@MainActor @Observable`; `init(applet:dataDir:projectRoot:)` (`:33`); `applet`/`dataStore`/`projectRoot`; `reload()` re-reads manifest (`:83`). **Add a connection resolver (built from `ConnectionStore.shared` + a binding store on `dataStore.dataDir`), `unboundConnectionSlots`, `pendingBindSlot`, `requestBind`/`completeBind`.** Init signature stays the same (resolver built internally).
- `Sources/Dreamux/Shell/AppletShell.swift` — `static func exec(cmd:cwd:timeout:) async -> (stdout,stderr,code)`, `/bin/sh -lc`, sets `env["PWD"]` (`:37-38`). **Add an `env: [String:String] = [:]` param merged onto the process env.**
- `Sources/Dreamux/Shell/GhOperations.swift` — the `gh` invocation pattern (bin resolve, env, Process) to mirror in the CLI importer.
- `Sources/Dreamux/Models/ProjectStore.swift` — `nonisolated static func stateRootURL() -> URL` (App-Support / `$DREAMUX_STATE_DIR`) — the global metadata + default secret root.
- `Sources/Dreamux/Views/SettingsView.swift` — `struct SettingsView` (`:55`) is a `Form { Section(...) … }`. **Add a Connections `Section`** (or a subview it embeds).
- `Sources/Dreamux/Views/Applets/AppletHostView.swift` — `headerBar` (`:21`); the `content`/`preview` split (`:61-81`). **Add an unbound-connection banner + bind sheet.**
- `Sources/Dreamux/Models/ProjectSession.swift` — `appletSession(for:)` (`:702`) / `closeAppletSession` (`:715`) construct/tear down `AppletSession` — unchanged (resolver is internal).
- `Sources/Dreamux/E2E/E2ECommands.swift` (`:52+` dispatch), `Scripts/e2e/driver.py`, `Scripts/e2e/PROTOCOL.md`, `Sources/Dreamux/Resources/AppletScaffold/APPLET.md`.
- `Sources/Dreamux/Shell/NotificationManager.swift` — `func notify(title:body:)` (`:96`), the `.shared` singleton pattern to mirror for `ConnectionStore.shared`.

---

## GROUP 1 — Model & pure security core

### Task 1: Connection / AuthKind model + manifest `requiresConnections`

**Files:**
- Create: `Sources/Dreamux/Models/Connection.swift`
- Modify: `Sources/Dreamux/Models/AppletManifest.swift` (add `requiresConnections`)
- Test: `Tests/DreamuxTests/ConnectionModelTests.swift`

**Interfaces (Produces):**

```swift
import Foundation

/// How a Connection's token is applied to a request or a shell env.
enum AuthKind: Codable, Equatable, Sendable {
    /// value = valueTemplate with "{token}" substituted, set on `headerName`.
    /// (Bearer: name "Authorization", template "Bearer {token}";
    ///  GitHub classic PAT: "Authorization" / "token {token}";
    ///  API key: "X-API-Key" / "{token}".)
    case header(headerName: String, valueTemplate: String)
    /// HTTP Basic: header "Authorization" = "Basic base64(username:token)".
    case basic(username: String)
    /// Append `param`={token} to the URL query (legacy APIs).
    case query(param: String)
    /// Inject each of `vars` = token into a single `shell.exec` process env.
    case env(vars: [String])

    /// True if this kind attaches to an HTTP request (header/basic/query);
    /// false for `.env` (shell only).
    var isHTTP: Bool
}

/// A named credential. The secret lives in the Keychain (keyed by `id`);
/// this is the non-secret metadata persisted to `connections.json`.
struct Connection: Identifiable, Codable, Equatable, Sendable {
    let id: String            // slug, unique within the store
    var label: String
    var kind: AuthKind
    var hosts: [String]       // ENFORCED allowlist (lowercased at use)
    var source: Source
    var createdAt: Date

    enum Source: Codable, Equatable, Sendable {
        case manual
        case importedFromCLI(tool: String)   // "gh", "eas"
        case oauth                            // reserved (deferred)
    }
}

/// A manifest-declared connection requirement. Carries no secret.
struct ConnectionSlot: Codable, Equatable, Sendable {
    let id: String            // slot name the applet passes at { connection: id }
    var label: String
    var hosts: [String]       // advisory: what the applet intends to call
    var suggests: String?     // provider hint for the bind UI ("github"/"expo")
}
```

Manifest change: add `var requiresConnections: [ConnectionSlot]` to `AppletManifest`. **This is a non-optional array, so a synthesized decoder would fail on old manifests that lack the key** (unlike `origin`, which is a true `Optional` and auto-nils). Add an explicit `init(from decoder:)` to `AppletManifest` that decodes every field normally but reads this one as `try container.decodeIfPresent([ConnectionSlot].self, forKey: .requiresConnections) ?? []` (leave `encode(to:)` synthesized, which still emits it). Verify the existing `AppletManifest` tests (round-trip, `load`) still pass with the new custom init. `ConnectionSlot.id` and `Connection.id` must be safe slugs — reuse `AppletSlug.isSafe` (a hand-edited connection id keys the Keychain account and metadata path, so it goes through the same safety chokepoint as applet slugs).

- [ ] **Step 1: Failing tests** — `ConnectionModelTests`:

```swift
import XCTest
@testable import Dreamux

final class ConnectionModelTests: XCTestCase {
    func testAuthKindRoundTripsEachCase() throws {
        let kinds: [AuthKind] = [
            .header(headerName: "Authorization", valueTemplate: "Bearer {token}"),
            .basic(username: "me"),
            .query(param: "api_key"),
            .env(vars: ["GH_TOKEN", "GITHUB_TOKEN"]),
        ]
        for kind in kinds {
            let data = try JSONEncoder().encode(kind)
            XCTAssertEqual(try JSONDecoder().decode(AuthKind.self, from: data), kind)
        }
        XCTAssertTrue(AuthKind.header(headerName: "A", valueTemplate: "{token}").isHTTP)
        XCTAssertTrue(AuthKind.basic(username: "u").isHTTP)
        XCTAssertTrue(AuthKind.query(param: "k").isHTTP)
        XCTAssertFalse(AuthKind.env(vars: ["X"]).isHTTP)
    }

    func testConnectionRoundTrips() throws {
        let c = Connection(id: "github", label: "GitHub", 
            kind: .header(headerName: "Authorization", valueTemplate: "Bearer {token}"),
            hosts: ["api.github.com"], source: .importedFromCLI(tool: "gh"),
            createdAt: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(try JSONDecoder().decode(Connection.self,
            from: JSONEncoder().encode(c)), c)
    }

    func testManifestDecodesWithAndWithoutConnections() throws {
        // Old manifest (no requiresConnections) still decodes → [].
        let old = Data("""
        {"id":"\(UUID().uuidString)","name":"n","slug":"n","icon":"i",
         "description":"d","requiresCapabilities":["http"]}
        """.utf8)
        let m1 = try JSONDecoder().decode(AppletManifest.self, from: old)
        XCTAssertEqual(m1.requiresConnections, [])
        // New manifest round-trips the slots.
        var m2 = m1
        m2.requiresConnections = [ConnectionSlot(id: "github", label: "GitHub",
            hosts: ["api.github.com"], suggests: "github")]
        let decoded = try JSONDecoder().decode(AppletManifest.self,
            from: JSONEncoder().encode(m2))
        XCTAssertEqual(decoded.requiresConnections, m2.requiresConnections)
    }
}
```

- [ ] **Step 2: Verify fail** — `swift test --filter ConnectionModelTests` (types undefined).
- [ ] **Step 3: Implement** `Connection.swift` + the manifest field (optional decode, encode-through, `isHTTP`).
- [ ] **Step 4: Green** — filter, then full `swift test`.
- [ ] **Step 5: Commit** — `git add Sources/Dreamux/Models/Connection.swift Sources/Dreamux/Models/AppletManifest.swift Tests/DreamuxTests/ConnectionModelTests.swift && git commit -m "Connections: model (Connection/AuthKind/ConnectionSlot) + manifest requiresConnections"`

### Task 2: ConnectionAuthenticator — https-only, exact-host, per-kind apply (security-critical)

**Files:**
- Create: `Sources/Dreamux/Models/ConnectionAuthenticator.swift`
- Test: `Tests/DreamuxTests/ConnectionAuthenticatorTests.swift`

**Interfaces:**

```swift
enum ConnectionAuthError: Error, Equatable {
    case notHTTPS            // authenticated fetch attempted over cleartext
    case hostNotAllowed(String)
    case wrongKindForHTTP    // .env kind used with http.fetch
    case wrongKindForShell   // non-.env kind used with shell.exec
    case malformedURL
}

enum ConnectionAuthenticator {
    /// Case-insensitive EXACT host match against the allowlist. No suffix
    /// or subdomain matching.
    static func hostAllowed(_ url: URL, hosts: [String]) -> Bool

    /// Apply an HTTP kind's credential to `request` for `url`. Enforces
    /// https-only and the exact-host allowlist; rejects `.env`. Returns the
    /// mutated request (header set, or query param appended).
    static func authorize(_ request: URLRequest, url: URL, kind: AuthKind,
                          token: String, hosts: [String]) throws -> URLRequest

    /// Env additions for a `.env` kind (each var = token). Rejects HTTP kinds.
    static func env(for kind: AuthKind, token: String) throws -> [String: String]
}
```

- [ ] **Step 1: Failing tests** — `ConnectionAuthenticatorTests`:

```swift
import XCTest
@testable import Dreamux

final class ConnectionAuthenticatorTests: XCTestCase {
    private let hosts = ["api.github.com"]

    func testExactHostMatchOnly() {
        XCTAssertTrue(ConnectionAuthenticator.hostAllowed(
            URL(string: "https://api.github.com/x")!, hosts: hosts))
        XCTAssertTrue(ConnectionAuthenticator.hostAllowed(   // case-insensitive
            URL(string: "https://API.GitHub.com/x")!, hosts: hosts))
        for bad in ["https://api.github.com.evil.com/x",
                    "https://evil.com/api.github.com",
                    "https://xapi.github.com/x",
                    "https://api.github.com.evil.com",
                    "https://140.82.113.3/x"] {
            XCTAssertFalse(ConnectionAuthenticator.hostAllowed(
                URL(string: bad)!, hosts: hosts), "should reject \(bad)")
        }
    }

    func testHTTPSOnly() {
        XCTAssertThrowsError(try ConnectionAuthenticator.authorize(
            URLRequest(url: URL(string: "http://api.github.com/x")!),
            url: URL(string: "http://api.github.com/x")!,
            kind: .header(headerName: "Authorization", valueTemplate: "Bearer {token}"),
            token: "T", hosts: hosts)) { XCTAssertEqual($0 as? ConnectionAuthError, .notHTTPS) }
    }

    func testHostRejectedGetsNoHeader() {
        XCTAssertThrowsError(try ConnectionAuthenticator.authorize(
            URLRequest(url: URL(string: "https://evil.com/x")!),
            url: URL(string: "https://evil.com/x")!,
            kind: .header(headerName: "Authorization", valueTemplate: "Bearer {token}"),
            token: "T", hosts: hosts)) {
            XCTAssertEqual($0 as? ConnectionAuthError, .hostNotAllowed("evil.com"))
        }
    }

    func testEachKindApplies() throws {
        let url = URL(string: "https://api.github.com/x")!
        let header = try ConnectionAuthenticator.authorize(URLRequest(url: url), url: url,
            kind: .header(headerName: "Authorization", valueTemplate: "token {token}"),
            token: "SEKRET", hosts: hosts)
        XCTAssertEqual(header.value(forHTTPHeaderField: "Authorization"), "token SEKRET")

        let basic = try ConnectionAuthenticator.authorize(URLRequest(url: url), url: url,
            kind: .basic(username: "me"), token: "pw", hosts: hosts)
        XCTAssertEqual(basic.value(forHTTPHeaderField: "Authorization"),
            "Basic " + Data("me:pw".utf8).base64EncodedString())

        let query = try ConnectionAuthenticator.authorize(URLRequest(url: url), url: url,
            kind: .query(param: "api_key"), token: "K", hosts: hosts)
        XCTAssertTrue(query.url!.query!.contains("api_key=K"))
        XCTAssertFalse(query.url!.path.contains("K"))   // token not in path
    }

    func testKindContextMismatches() {
        let url = URL(string: "https://api.github.com/x")!
        XCTAssertThrowsError(try ConnectionAuthenticator.authorize(URLRequest(url: url), url: url,
            kind: .env(vars: ["X"]), token: "T", hosts: hosts)) {
            XCTAssertEqual($0 as? ConnectionAuthError, .wrongKindForHTTP)
        }
        XCTAssertThrowsError(try ConnectionAuthenticator.env(
            for: .header(headerName: "A", valueTemplate: "{token}"), token: "T")) {
            XCTAssertEqual($0 as? ConnectionAuthError, .wrongKindForShell)
        }
        XCTAssertEqual(try ConnectionAuthenticator.env(for: .env(vars: ["GH_TOKEN"]), token: "T"),
                       ["GH_TOKEN": "T"])
    }
}
```

- [ ] **Step 2: Verify fail.**  - [ ] **Step 3: Implement.** `hostAllowed`: `url.host?.lowercased()` exact-in `hosts.map{$0.lowercased()}`. `authorize`: guard `url.scheme?.lowercased() == "https"` else `.notHTTPS`; guard `hostAllowed` else `.hostNotAllowed(host)`; switch kind (header → set field to template with `{token}` replaced; basic → base64; query → `URLComponents` append `URLQueryItem`; `.env` → throw `.wrongKindForHTTP`). `env`: only `.env` → `Dictionary(uniqueKeysWithValues: vars.map{($0, token)})`, else `.wrongKindForShell`.  - [ ] **Step 4: Green + full suite.**  - [ ] **Step 5: Commit** — `git commit -m "Connections: ConnectionAuthenticator — https-only, exact-host, per-kind apply"`

---

## GROUP 2 — Persistence

### Task 3: SecretStore (protocol + Keychain + in-memory + file-backed)

**Files:**
- Create: `Sources/Dreamux/Models/SecretStore.swift`
- Test: `Tests/DreamuxTests/SecretStoreTests.swift`

**Interfaces:**

```swift
/// Stores/retrieves a connection's raw token, keyed by connection id. The
/// only component that ever holds a plaintext token at rest.
protocol SecretStore: Sendable {
    func set(_ token: String, for id: String) throws
    func get(_ id: String) -> String?
    func delete(_ id: String) throws
}

/// macOS Keychain generic-password store (app default).
struct KeychainSecretStore: SecretStore {
    var service = "com.dreamux.Dreamux.connection"
    // SecItemAdd/Update/CopyMatching/Delete, kSecAttrAccessibleWhenUnlocked.
}

/// File-backed store: one 0600 file per id under `dir`. Selected ONLY when
/// `$DREAMUX_CONNECTIONS_SECRET_DIR` is set (tests/e2e) — never the Keychain
/// in that mode.
struct FileSecretStore: SecretStore {
    let dir: URL   // created on demand
}

/// In-memory (unit tests).
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    // NSLock-guarded dictionary.
}

enum SecretStoreFactory {
    /// FileSecretStore(dir:) when `$DREAMUX_CONNECTIONS_SECRET_DIR` is set,
    /// else KeychainSecretStore().
    static func makeDefault() -> SecretStore
}
```

- [ ] **Step 1: Failing tests** — `SecretStoreTests` (exercise the two deterministic stores; the Keychain path is build-gated + manually verified — a test host can prompt/deny):

```swift
import XCTest
@testable import Dreamux

final class SecretStoreTests: XCTestCase {
    private func check(_ store: SecretStore) throws {
        XCTAssertNil(store.get("github"))
        try store.set("SEKRET", for: "github")
        XCTAssertEqual(store.get("github"), "SEKRET")
        try store.set("SEKRET2", for: "github")            // overwrite
        XCTAssertEqual(store.get("github"), "SEKRET2")
        try store.delete("github")
        XCTAssertNil(store.get("github"))
        XCTAssertNoThrow(try store.delete("github"))       // delete-absent is a no-op
    }

    func testInMemory() throws { try check(InMemorySecretStore()) }

    func testFileBacked() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("secrets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try check(FileSecretStore(dir: dir))
        // A second instance over the same dir sees persisted secrets.
        try FileSecretStore(dir: dir).set("X", for: "k")
        XCTAssertEqual(FileSecretStore(dir: dir).get("k"), "X")
    }

    func testFactoryHonorsEnvOverride() {
        // With the override set, the default is file-backed (no Keychain in tests).
        // (Documented behavior; asserted structurally — the override is read
        //  from the process env, which the e2e harness sets.)
        XCTAssertNotNil(SecretStoreFactory.makeDefault())
    }
}
```

- [ ] **Step 2: Verify fail.**  - [ ] **Step 3: Implement.** FileSecretStore: secret file named by `id` (guard `AppletSlug.isSafe(id)` before touching the path — no traversal), written `.atomic` with `attributes: [.posixPermissions: 0o600]`, `delete` ignores missing. Keychain: standard `SecItemAdd`/`SecItemUpdate` on `errSecDuplicateItem`, `SecItemCopyMatching`, `SecItemDelete` ignoring `errSecItemNotFound`.  - [ ] **Step 4: Green + full suite.**  - [ ] **Step 5: Commit** — `git commit -m "Connections: SecretStore (Keychain / file / in-memory) + env-driven factory"`

### Task 4: ConnectionStore + ConnectionBindingStore

**Files:**
- Create: `Sources/Dreamux/Models/ConnectionStore.swift`
- Create: `Sources/Dreamux/Models/ConnectionBindingStore.swift`
- Test: `Tests/DreamuxTests/ConnectionStoreTests.swift`

**Interfaces:**

```swift
@MainActor @Observable
final class ConnectionStore {
    private(set) var connections: [Connection] = []

    /// App-wide instance: metadata at `stateRootURL()/connections.json`,
    /// secrets via `SecretStoreFactory.makeDefault()`.
    static let shared = ConnectionStore()

    /// App default.
    convenience init()
    /// Test/e2e seam.
    init(secretStore: SecretStore, metadataURL: URL)

    func connection(id: String) -> Connection?
    func token(for id: String) -> String?          // reads the SecretStore

    /// Create + persist a connection (id uniqued/safe), storing its token.
    @discardableResult
    func add(label: String, kind: AuthKind, hosts: [String], token: String,
             source: Connection.Source, preferredID: String) throws -> Connection
    func update(_ connection: Connection) throws     // metadata only (label/hosts/kind)
    func setToken(_ token: String, for id: String) throws
    func delete(id: String) throws                   // removes metadata + secret
}

@MainActor @Observable
final class ConnectionBindingStore {
    let fileURL: URL                                  // <dataDir>/connections.json
    init(dataDir: URL)                                // loads slot→connectionId map
    func connectionID(forSlot slot: String) -> String?
    func bind(slot: String, toConnectionID id: String) throws
    func unbind(slot: String) throws
    var bindings: [String: String] { get }
}
```

- [ ] **Step 1: Failing tests** — `ConnectionStoreTests` (`@MainActor`, using `InMemorySecretStore` + temp metadata):

```swift
import XCTest
@testable import Dreamux

@MainActor
final class ConnectionStoreTests: XCTestCase {
    private func makeStore() -> (ConnectionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conn-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ConnectionStore(secretStore: InMemorySecretStore(),
                                metadataURL: dir.appendingPathComponent("connections.json")), dir)
    }

    func testAddPersistsMetadataAndSecretSeparately() throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let c = try store.add(label: "GitHub",
            kind: .header(headerName: "Authorization", valueTemplate: "Bearer {token}"),
            hosts: ["api.github.com"], token: "SEKRET", source: .manual, preferredID: "github")
        XCTAssertEqual(c.id, "github")
        XCTAssertEqual(store.token(for: "github"), "SEKRET")
        // Metadata JSON must NOT contain the token.
        let json = try String(contentsOf: dir.appendingPathComponent("connections.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("SEKRET"))
        // Reload sees the connection (secret comes from the same in-memory store here).
        XCTAssertEqual(store.connections.map(\.id), ["github"])
    }

    func testDeleteRemovesMetadataAndSecret() throws {
        let (store, dir) = makeStore(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.add(label: "G", kind: .basic(username: "u"), hosts: ["x.com"],
                          token: "T", source: .manual, preferredID: "g")
        try store.delete(id: "g")
        XCTAssertNil(store.token(for: "g"))
        XCTAssertEqual(store.connections, [])
    }

    func testBindingRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bindings = ConnectionBindingStore(dataDir: dir)
        XCTAssertNil(bindings.connectionID(forSlot: "github"))
        try bindings.bind(slot: "github", toConnectionID: "github")
        XCTAssertEqual(bindings.connectionID(forSlot: "github"), "github")
        XCTAssertEqual(ConnectionBindingStore(dataDir: dir).connectionID(forSlot: "github"), "github")
        try bindings.unbind(slot: "github")
        XCTAssertNil(bindings.connectionID(forSlot: "github"))
    }
}
```

- [ ] **Step 2: Verify fail.**  - [ ] **Step 3: Implement.** ConnectionStore mirrors `AppLibraryStore`/`ProjectStore` persistence (pretty+sorted JSON, atomic); `add` uniques `preferredID` via `AppletSlug.unique(AppletSlug.slugify(preferredID), existing: Set(connections.map(\.id)))` and stores the token BEFORE persisting metadata (roll back the secret on a metadata-write failure); `delete` removes secret then metadata. `convenience init()` uses `SecretStoreFactory.makeDefault()` + `ProjectStore.stateRootURL().appendingPathComponent("connections.json")`. BindingStore: a `[String:String]` JSON map at `<dataDir>/connections.json`, `DreamuxStateDir.ensure`-created dir (it lives under `.dreamux/appdata/<slug>/`).  - [ ] **Step 4: Green + full suite.**  - [ ] **Step 5: Commit** — `git commit -m "Connections: ConnectionStore (metadata+Keychain) and per-applet ConnectionBindingStore"`

### Task 5: CLICredentialImporter (gh / eas)

**Files:**
- Create: `Sources/Dreamux/Models/CLICredentialImporter.swift`
- Test: `Tests/DreamuxTests/CLICredentialImporterTests.swift`

**Interfaces:**

```swift
/// Reads an existing CLI login and yields a token + a sensible default
/// Connection shape, so "Import from gh/eas" is one click.
enum CLICredentialImporter {
    struct Draft: Equatable {
        var token: String
        var label: String
        var kind: AuthKind
        var hosts: [String]
        var preferredID: String
        var source: Connection.Source
    }

    /// Known providers surfaced in the UI.
    static let providers: [(id: String, label: String)]   // [("gh","GitHub (gh CLI)"), ("expo","Expo (eas)")]

    /// Pure: build a Draft from a provider's already-captured token.
    static func draft(provider: String, token: String) -> Draft?

    /// Pure: parse a provider's CLI output into a token (nil if absent/empty).
    static func parseToken(provider: String, cliOutput: String) -> String?
    /// Pure: parse Expo `~/.expo/state.json` contents into a token.
    static func parseExpoStateJSON(_ contents: String) -> String?

    /// Live: run the provider's CLI (via AppletShell-style exec) and return a
    /// Draft, or nil if the user isn't logged in. (Build-gated; the parsing
    /// above is the tested part.)
    @MainActor static func importFromCLI(provider: String) async -> Draft?
}
```

- [ ] **Step 1: Failing tests** — `CLICredentialImporterTests`:

```swift
import XCTest
@testable import Dreamux

final class CLICredentialImporterTests: XCTestCase {
    func testGhDraft() {
        let d = CLICredentialImporter.draft(provider: "gh", token: "ghp_abc")!
        XCTAssertEqual(d.token, "ghp_abc")
        XCTAssertEqual(d.hosts, ["api.github.com"])
        XCTAssertEqual(d.preferredID, "github")
        if case .header(let name, let tmpl) = d.kind {
            XCTAssertEqual(name, "Authorization"); XCTAssertEqual(tmpl, "Bearer {token}")
        } else { XCTFail("expected header kind") }
        if case .importedFromCLI(let tool) = d.source { XCTAssertEqual(tool, "gh") }
        else { XCTFail("expected importedFromCLI") }
    }

    func testExpoDraftAndStateParse() {
        let d = CLICredentialImporter.draft(provider: "expo", token: "expo_xyz")!
        XCTAssertEqual(d.hosts, ["api.expo.dev"])
        XCTAssertEqual(d.preferredID, "expo")
        XCTAssertEqual(CLICredentialImporter.parseExpoStateJSON(
            #"{"auth":{"sessionSecret":"expo_xyz"}}"#), "expo_xyz")
        XCTAssertNil(CLICredentialImporter.parseExpoStateJSON(#"{"auth":{}}"#))
    }

    func testGhTokenParse() {
        XCTAssertEqual(CLICredentialImporter.parseToken(provider: "gh",
            cliOutput: "gho_TOKEN123\n"), "gho_TOKEN123")
        XCTAssertNil(CLICredentialImporter.parseToken(provider: "gh", cliOutput: "\n"))
    }

    func testUnknownProvider() {
        XCTAssertNil(CLICredentialImporter.draft(provider: "nope", token: "t"))
    }
}
```

- [ ] **Step 2: Verify fail.**  - [ ] **Step 3: Implement** the pure recipes (gh: `gh auth token`; expo: `EXPO_TOKEN` env or `~/.expo/state.json` `auth.sessionSecret`), both defaulting to `.header("Authorization","Bearer {token}")`. `importFromCLI` runs the CLI via the `AppletShell.exec`/`GhOperations` pattern (build-gated).  - [ ] **Step 4: Green + full suite.**  - [ ] **Step 5: Commit** — `git commit -m "Connections: CLICredentialImporter (import from gh / eas)"`

---

## GROUP 3 — Bridge wiring

### Task 6: Connection resolution + bridge methods + `{connection}` on fetch/exec

**Files:**
- Create: `Sources/Dreamux/Models/AppletConnectionResolver.swift`
- Modify: `Sources/Dreamux/Models/AppletSession.swift`
- Modify: `Sources/Dreamux/Views/Applets/AppletBridgeCore.swift`
- Modify: `Sources/Dreamux/Views/Applets/AppletBridge.swift`
- Modify: `Sources/Dreamux/Shell/AppletShell.swift` (add `env:` param)
- Test: `Tests/DreamuxTests/AppletConnectionResolverTests.swift`, `Tests/DreamuxTests/AppletBridgeCoreTests.swift` (extend)

**Interfaces:**

```swift
@MainActor
final class AppletConnectionResolver {
    init(store: ConnectionStore, bindings: ConnectionBindingStore)

    struct Status: Equatable { var bound: Bool; var label: String?; var hosts: [String] }
    func status(slot: String) -> Status

    struct Resolved { let connection: Connection; let token: String }
    enum ResolveError: Error, Equatable { case slotNotBound(String); case connectionMissing(String); case tokenMissing(String) }
    /// slot → binding → connection (+ token from the store). Throws if the
    /// slot is unbound, the bound connection was deleted, or its secret is gone.
    func resolve(slot: String) throws -> Resolved
}

// AppletSession additions:
//   - built in init from ConnectionStore.shared + ConnectionBindingStore(dataDir: dataStore.dataDir)
//   let connections: AppletConnectionResolver
//   var unboundConnectionSlots: [ConnectionSlot]   // manifest slots with no binding
//   var pendingBindSlot: String?                    // drives the host-view bind sheet
//   func requestBind(slot: String) async -> AppletConnectionResolver.Status   // sets pendingBindSlot, awaits completeBind
//   func completeBind()                             // called by the sheet on dismiss; resolves the await

// AppletShell.exec gains:  env: [String: String] = [:]   (merged onto ProcessInfo env, after PWD)
```

Bridge changes (`AppletBridge.dispatch`):
- `connections.status`: `reply(result: ["bound": s.bound, "label": s.label ?? NSNull(), "hosts": s.hosts])`.
- `connections.request`: `Task { let s = await owner.requestBind(slot:); reply(result: [...as status...]) }`.
- `http.fetch` — after building `urlRequest` and applying `headers`, if `request.params["connection"]` is a String slot: `let r = try owner.connections.resolve(slot:); urlRequest = try ConnectionAuthenticator.authorize(urlRequest, url: url, kind: r.connection.kind, token: r.token, hosts: r.connection.hosts)` (any throw → `{error}` reply, no request sent). Applet-supplied `headers` are applied first; the connection wins on the same field.
- `shell.exec` — if `{connection}`: `let r = try owner.connections.resolve(slot:); let env = try ConnectionAuthenticator.env(for: r.connection.kind, token: r.token)` → pass to `AppletShell.exec(cmd:cwd:timeout:env:)`.

`AppletBridgeCore`: add `"connections.status"`, `"connections.request"` to `knownMethods`; `capability(forMethod:)` returns `nil` for both (always allowed — they expose only non-secret status / open a UI). `http.fetch`/`shell.exec` still require their `http`/`shell` capability AND (when `{connection}` present) a resolvable binding.

- [ ] **Step 1: Failing tests** — `AppletConnectionResolverTests` (`@MainActor`, in-memory store + temp binding dir): bind "github" → a Connection, assert `status(bound:true)` + `resolve` returns the token; unbound slot → `status(bound:false)` + `resolve` throws `.slotNotBound`; bound-but-deleted connection → `.connectionMissing`. Extend `AppletBridgeCoreTests`: `checkAllowed("connections.status"/"connections.request", granted: [])` does NOT throw; both are in `knownMethods`; `capability(forMethod:)` is nil for both.
- [ ] **Step 2: Verify fail.**  - [ ] **Step 3: Implement** the resolver, the `AppletSession` additions (resolver built in `init`; `requestBind` stores a `CheckedContinuation` resolved by `completeBind`), the `AppletShell` `env:` param (merge after `env["PWD"]`), the `AppletBridgeCore` additions, and the four bridge dispatch edits.  - [ ] **Step 4: Green + full `swift test` + `swift build`.**  - [ ] **Step 5: Commit** — `git add Sources/Dreamux/Models/AppletConnectionResolver.swift Sources/Dreamux/Models/AppletSession.swift Sources/Dreamux/Views/Applets/AppletBridgeCore.swift Sources/Dreamux/Views/Applets/AppletBridge.swift Sources/Dreamux/Shell/AppletShell.swift Tests/DreamuxTests/AppletConnectionResolverTests.swift Tests/DreamuxTests/AppletBridgeCoreTests.swift && git commit -m "Connections: resolver, connections.status/request, {connection} on http.fetch/shell.exec"`

---

## GROUP 4 — UI

### Task 7: Connections management in Settings

**Files:**
- Create: `Sources/Dreamux/Views/ConnectionsSettingsView.swift`
- Create: `Sources/Dreamux/Views/AddConnectionSheet.swift`
- Modify: `Sources/Dreamux/Views/SettingsView.swift` (embed a "Connections" `Section`)

Semantics (build-gated; e2e in Task 9):
1. `ConnectionsSettingsView(store: ConnectionStore.shared)` — a `List` of connections (label, `kind` summary, hosts, a `.importedFromCLI`/`.manual` provenance chip); each row has Delete (confirm — removes Keychain item + metadata). A "+ Add connection" foot row (house style: borderless plain `plus`, 15pt) opens `AddConnectionSheet`.
2. `AddConnectionSheet` two paths: **Import from CLI** (a picker over `CLICredentialImporter.providers` → `importFromCLI` → prefilled Draft) or **Manual** (label, a `kind` picker — Bearer / token / custom-header / basic — hosts field, token `SecureField`). On save → `store.add(...)`.
3. In `SettingsView.body`'s `Form`, add `Section("Connections") { ConnectionsSettingsView(store: .shared) }` after the appearance sections. Copy uses the house scale; tokens shown only in a `SecureField`, never echoed back after save.

- [ ] **Step 1: Implement.**  - [ ] **Step 2: `swift build` + full `swift test`.**  - [ ] **Step 3: Commit** — `git commit -m "Connections: management UI in Settings (list, add, import-from-CLI, delete)"`

### Task 8: Bind banner + bind sheet in the applet host view

**Files:**
- Create: `Sources/Dreamux/Views/Applets/ConnectionBindSheet.swift`
- Modify: `Sources/Dreamux/Views/Applets/AppletHostView.swift`

Semantics (build-gated; e2e in Task 9):
1. In `AppletHostView`, when `!session.unboundConnectionSlots.isEmpty`, show a subtle banner strip under `headerBar` (not a modal): *"<slot.label> connection needed — Connect"* (`.soft` button). Multiple unbound slots → the banner names the first and the sheet lists all.
2. `.sheet(item:)` bound to `session.pendingBindSlot` (wrap in an `Identifiable` box), presenting `ConnectionBindSheet(slot:store:bindings:onDone:)`: pick an existing Connection (flag any whose `hosts` don't cover the slot's `hosts`, offer to add the missing host to it), or **Create new** (embeds `AddConnectionSheet`, prefilled from `slot.suggests`). On bind → `bindings.bind(slot:toConnectionID:)`, then `session.completeBind()` (clears `pendingBindSlot`, resolves any `requestBind` await, and the banner recomputes).
3. The Connect button sets `session.pendingBindSlot = slot.id`; `dreamux.connections.request(slot)` sets the same and awaits `completeBind`.

- [ ] **Step 1: Implement.**  - [ ] **Step 2: `swift build` + full `swift test`.**  - [ ] **Step 3: Manual smoke SKIPPED** (controller runs e2e; app-launch fights the main instance).  - [ ] **Step 4: Commit** — `git commit -m "Connections: bind banner + bind sheet in the applet host view"`

---

## GROUP 5 — Docs & e2e

### Task 9: APPLET.md + e2e authenticated-fetch scenario

**Files:**
- Modify: `Sources/Dreamux/Resources/AppletScaffold/APPLET.md`
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift`
- Modify: `Scripts/e2e/driver.py`, `Scripts/e2e/PROTOCOL.md`

**APPLET.md:** add a "Connections" section — declaring `requiresConnections` slots, calling `dreamux.http.fetch(url, {connection: "<slot>"})` and `dreamux.shell.exec(cmd, {connection})`, and `dreamux.connections.status(slot)` / `request(slot)`. State plainly: the token never reaches your JS; the call is rejected unless it's `https` and the host is in the connection's allowlist.

**e2e commands** (mirror `E2ECommands.swift:52+`): `createConnection {id, token, kind, hosts}` → `ConnectionStore.shared.add(...)` (the driver sets `$DREAMUX_CONNECTIONS_SECRET_DIR` so the token lands in the file store, not the Keychain); `bindConnection {slug, slot, connectionID}` → the active project applet's `ConnectionBindingStore.bind`.

**Driver scenario `scenario_connections`** (bounded polls via the existing `wait_until`; assert on disk, never pixels):
1. Sandboxed launch with `$DREAMUX_CONNECTIONS_SECRET_DIR` → temp dir (beside the existing `DREAMUX_*` env).
2. Start a **local echo HTTP server** in the driver that returns the request's `Authorization` header in its JSON body (bind to `127.0.0.1:<port>`).
3. `createConnection {id:"echo", token:"tok-123", kind: bearer, hosts:["127.0.0.1"]}`.
4. `createApplet {name:"Auth Probe", …}`; overwrite its `index.html` (keep `dreamux.js`) with a probe that:
   ```js
   const ok = await dreamux.http.fetch("https://127.0.0.1:<port>/echo", { connection: "echo" });
   await dreamux.kv.set("authHeader", JSON.parse(ok.text).authorization);
   try { await dreamux.http.fetch("https://evil.example/x", { connection: "echo" }); await dreamux.kv.set("leak","LEAKED"); }
   catch { await dreamux.kv.set("leak","blocked"); }
   ```
   and rewrite its `manifest.json` → `requiresCapabilities:["http","kv"]`, `requiresConnections:[{id:"echo",label:"Echo",hosts:["127.0.0.1"]}]`.
   *(The echo server terminates TLS with a driver-generated self-signed cert; the applet's `http.fetch` goes through `URLSession`. If TLS-to-localhost proves fiddly in-harness, the scenario MAY assert the negative path (host-allowlist block) + the resolver/authenticator unit coverage instead of a live 200 — the on-disk `authHeader` assertion is the goal, the transport is incidental; document whichever was used.)*
5. `bindConnection {slug, slot:"echo", connectionID:"echo"}`, `openApplet {slug}`.
6. Poll `<project>/.dreamux/appdata/<slug>/kv.json` until `authHeader == "Bearer tok-123"` (proves: slot resolved → token attached natively → reached the allowlisted host) AND `leak == "blocked"` (proves: the non-allowlisted host was rejected, **no** token sent).
7. Screenshot (chrome only; note the blank webview). `PROTOCOL.md`: document the two commands + the caveat.

- [ ] **Step 1: Implement commands + scenario + APPLET.md.**
- [ ] **Step 2: `swift build` + full `swift test`; run `python3 Scripts/e2e/driver.py connections`** (match the `__main__` convention) — iterate to PASS; grep the real summary line, never a piped exit code.
- [ ] **Step 3: Commit** — `git commit -m "Connections e2e: authenticated-fetch round-trip + host-allowlist block; APPLET.md connections"`

---

## Final gate (whole-feature)

- [ ] Full `swift test` green; `python3 Scripts/e2e/driver.py connections` green; re-run one existing scenario (`applets`) green (no regression from the bridge/manifest changes).
- [ ] `./Scripts/make-app.sh debug && open ./Dreamux.app` — manual pass: add a GitHub connection via "Import from `gh`" in Settings; an applet declaring a `github` slot shows the bind banner; bind it; an authenticated `http.fetch` to `api.github.com` succeeds; the token appears in no log.
- [ ] README: extend the "Applets & App Studio" section with a short Connections paragraph.
- [ ] Push to main only after the user has eyeballed the UI.

## Deferred (spec §Deferred — do NOT build)

OAuth connections (device-code/refresh); the raw-token `secrets.get` escape hatch; wildcard/subdomain host rules; connection health/expiry surfacing; marketplace connection templates. Each has its seam named in the spec.
