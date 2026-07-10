# Applet Connections Generalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make token-based Connections fully ad-hoc — an applet declares its own auth recipe in the manifest, the manual editor accepts any header template + query auth, and any CLI login imports via a generic command — so Dreamux hardcodes nothing service-specific (`gh`/`expo` become presets, not the ceiling). OAuth stays deferred.

**Architecture:** Extends the shipped Connections feature (same branch, pre-merge). `ConnectionSlot` gains optional `authKind`/`importCommand` recipe fields; `CLICredentialImporter` gains a generic `runCommand`; `AddConnectionSheet` exposes a freeform header template + query kind + custom-command import; `ConnectionBindSheet` pre-fills Create-new from a slot's recipe and surfaces its import command (user-triggered, never auto-run). The security core (`ConnectionAuthenticator`, Keychain, host allowlist + redirect guard) is unchanged — recipes are inert data through it.

**Tech Stack:** Swift 6 / SwiftPM, SwiftUI, XCTest, e2e harness.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-10-applet-connections-generalization-design.md` (read it first); parent: `2026-07-10-applet-connections-design.md`.
- **No new security surface.** A freeform header template is inert data applied only through the existing `ConnectionAuthenticator` (https-only, exact-host, `{token}`-required, redirect-guarded). Connection ids still `slugify` at construction.
- **Consent rule (load-bearing):** an `importCommand` — user-typed OR carried in an applet slot's recipe — is shell run at user privilege. It is **always shown to the user and executed ONLY on the user's explicit click**, never auto-run on adopt/open/bind.
- **Back-compat:** the new `ConnectionSlot` fields are Optional → old manifests decode unchanged. A recipe-less slot behaves exactly as today.
- **The recipe carries no secret** — marketplace-safe.
- Swift 6; pure helpers `nonisolated static`, unit-tested; UI is build-gated (house style — no unit tests for SwiftUI views; e2e/manual covers it). Full `swift test` + `swift build` green before every commit; stage only named files; re-verify HEAD.
- House style: `.buttonStyle(.soft)`, `.roundedBorder` text fields, secondary captions, 460-wide sheet — match the existing `AddConnectionSheet`.

## Adaptation ground rules

Anchors verified at HEAD (branch `worktree-app-connections`, `9e86ac6`).

- `Sources/Dreamux/Models/Connection.swift` — `struct ConnectionSlot: Codable, Equatable, Sendable { let id; var label; var hosts; var suggests: String? }`; `enum AuthKind` (`.header(headerName:valueTemplate:)`/`.basic(username:)`/`.query(param:)`/`.env(vars:)`, synthesized `Codable`).
- `Sources/Dreamux/Models/CLICredentialImporter.swift` — `struct Draft`, `providers: [(id,label)]`, `draft(provider:token:)`, `parseToken(provider:cliOutput:)`, `parseExpoStateJSON(_:)`, `importFromCLI(provider:)`, and the private `runGhAuthToken()` Process plumbing (`:120-158`) to mirror for the generic runner.
- `Sources/Dreamux/Views/AddConnectionSheet.swift` — `var suggestedProvider: String? = nil` (:16), `enum KindChoice { bearer, apiKey, basic, env }` (:28-34), `@State` fields (:40-63), `importSection` (:141), `runImport()` (:184), `applyDraft(_:)` (:204-231), `manualFieldsSection` (:235-288), `kindFieldsValid` (:321-328), `effectiveKind` (:338-351), `save()` (:367). It's build-gated (no unit tests).
- `Sources/Dreamux/Views/Applets/ConnectionBindSheet.swift` — presents `AddConnectionSheet(store:suggestedProvider: slot.suggests, onDone:)` for Create-new; has the `ConnectionSlot` (`slot`) in scope.
- `Sources/Dreamux/Resources/AppletScaffold/APPLET.md` — the Connections section (added in the parent's T9).
- `Sources/Dreamux/E2E/E2ECommands.swift` — `createConnection`/`bindConnection`/`connectionsState`; `Scripts/e2e/driver.py` `scenario_connections`; `Scripts/e2e/PROTOCOL.md`.
- `Sources/Dreamux/Models/ConnectionStore.swift` — `add(label:kind:hosts:token:source:preferredID:)`.

---

### Task 1: Applet-declared recipe on ConnectionSlot (+ APPLET.md)

**Files:**
- Modify: `Sources/Dreamux/Models/Connection.swift` (add recipe fields to `ConnectionSlot`)
- Modify: `Sources/Dreamux/Resources/AppletScaffold/APPLET.md` (document the recipe fields)
- Test: `Tests/DreamuxTests/ConnectionModelTests.swift` (extend)

**Interfaces (Produces):**

```swift
struct ConnectionSlot: Codable, Equatable, Sendable {
    let id: String
    var label: String
    var hosts: [String]
    var suggests: String?
    var authKind: AuthKind?      // NEW — the exact auth shape the applet's service needs
    var importCommand: String?   // NEW — a suggested command that prints the token
}
```

Both new fields are Optional, so the synthesized `Codable` decodes an old slot (no `authKind`/`importCommand` keys) to `nil` — no custom init needed. Add them to the memberwise usage sites if `ConnectionSlot` is constructed anywhere with all fields named (grep first; today it's built in tests + decoded from JSON, and the manifest `requiresConnections` array decodes it — so a defaulted memberwise init `var authKind: AuthKind? = nil`, `var importCommand: String? = nil` keeps existing constructions compiling).

**APPLET.md:** add to the Connections section a "Declaring a connection recipe" subsection: an applet may put `authKind` and `importCommand` on a `requiresConnections` slot so binding pre-fills everything and the user supplies only the secret. Document the exact `authKind` JSON (Swift's synthesized enum shape) with examples:
```json
{ "id": "linear", "label": "Linear API key", "hosts": ["api.linear.app"],
  "authKind": { "header": { "headerName": "Authorization", "valueTemplate": "{token}" } } }
{ "id": "gh", "label": "GitHub", "hosts": ["api.github.com"],
  "authKind": { "header": { "headerName": "Authorization", "valueTemplate": "Bearer {token}" } },
  "importCommand": "gh auth token" }
```
…the other shapes (`{"basic":{"username":"…"}}`, `{"query":{"param":"…"}}`, `{"env":{"vars":["…"]}}`), the rule that a header `valueTemplate` MUST contain `{token}`, and a bold note that **an `importCommand` is only ever run when you click it — Dreamux never runs it automatically.**

- [ ] **Step 1: Failing test** — extend `ConnectionModelTests`:

```swift
func testConnectionSlotDecodesWithoutRecipeFields() throws {
    // Old slot (no authKind/importCommand) → nils, back-compat.
    let json = Data(#"{"id":"gh","label":"GitHub","hosts":["api.github.com"]}"#.utf8)
    let slot = try JSONDecoder().decode(ConnectionSlot.self, from: json)
    XCTAssertNil(slot.authKind)
    XCTAssertNil(slot.importCommand)
    XCTAssertNil(slot.suggests)
}

func testConnectionSlotRoundTripsFullRecipe() throws {
    let slot = ConnectionSlot(
        id: "linear", label: "Linear", hosts: ["api.linear.app"], suggests: nil,
        authKind: .header(headerName: "Authorization", valueTemplate: "{token}"),
        importCommand: "linear-cli token")
    let decoded = try JSONDecoder().decode(ConnectionSlot.self,
        from: JSONEncoder().encode(slot))
    XCTAssertEqual(decoded, slot)
    XCTAssertEqual(decoded.authKind, .header(headerName: "Authorization", valueTemplate: "{token}"))
    XCTAssertEqual(decoded.importCommand, "linear-cli token")
}

func testManifestWithRecipeSlotsStillDecodes() throws {
    let json = Data(#"""
    {"id":"00000000-0000-0000-0000-000000000000","name":"n","slug":"n","icon":"i",
     "description":"d","requiresCapabilities":["http"],
     "requiresConnections":[{"id":"gh","label":"GitHub","hosts":["api.github.com"],
       "authKind":{"header":{"headerName":"Authorization","valueTemplate":"Bearer {token}"}},
       "importCommand":"gh auth token"}]}
    """#.utf8)
    let m = try JSONDecoder().decode(AppletManifest.self, from: json)
    XCTAssertEqual(m.requiresConnections.first?.importCommand, "gh auth token")
    XCTAssertEqual(m.requiresConnections.first?.authKind,
        .header(headerName: "Authorization", valueTemplate: "Bearer {token}"))
}
```

- [ ] **Step 2: Verify fail** — `swift test --filter ConnectionModelTests` (new fields undefined / assertions fail).
- [ ] **Step 3: Implement** the two optional fields (defaulted in the memberwise init) + the APPLET.md subsection.
- [ ] **Step 4: Green** — filter, then full `swift test` (confirm the existing manifest/slot tests still pass).
- [ ] **Step 5: Commit** — `git add Sources/Dreamux/Models/Connection.swift Sources/Dreamux/Resources/AppletScaffold/APPLET.md Tests/DreamuxTests/ConnectionModelTests.swift && git commit -m "Connections: applet-declared recipe (authKind/importCommand) on ConnectionSlot"`

### Task 2: Generic command import in CLICredentialImporter

**Files:**
- Modify: `Sources/Dreamux/Models/CLICredentialImporter.swift`
- Test: `Tests/DreamuxTests/CLICredentialImporterTests.swift` (extend)

**Interfaces (Produces):**

```swift
extension CLICredentialImporter {
    /// Run an arbitrary user/applet-supplied command via `/bin/sh -lc` and
    /// return its trimmed stdout as a token, or nil on empty output / non-zero
    /// exit / launch failure. Off the main thread; stdout drained before wait.
    /// The command is ALWAYS user-triggered (never auto-run) — see the spec's
    /// consent rule; this is just the runner.
    static func runCommand(_ command: String) async -> String?
}
```

Mirror the existing `runGhAuthToken()` Process plumbing (`CLICredentialImporter.swift:120-158`): `Process` with `executableURL = /bin/sh`, `arguments = ["-lc", command]`, inherited env, out/err pipes drained before `waitUntilExit`; on non-zero exit or launch failure return nil; else `parseToken(provider:"", cliOutput: stdout)` (reuse the trim-and-nil-if-empty helper). Keep `providers`/`draft`/`importFromCLI` unchanged (the gh/expo presets stay).

- [ ] **Step 1: Failing test** — extend `CLICredentialImporterTests` (real shell commands → deterministic):

```swift
func testRunCommandCapturesTrimmedStdout() async {
    let token = await CLICredentialImporter.runCommand("printf 'tok-xyz\\n'")
    XCTAssertEqual(token, "tok-xyz")
}
func testRunCommandNilOnEmptyOutput() async {
    XCTAssertNil(await CLICredentialImporter.runCommand("true"))
    XCTAssertNil(await CLICredentialImporter.runCommand("printf '   '"))
}
func testRunCommandNilOnNonZeroExit() async {
    // A command that prints then fails must NOT yield a token.
    XCTAssertNil(await CLICredentialImporter.runCommand("echo oops; exit 3"))
}
```

- [ ] **Step 2: Verify fail** — `swift test --filter CLICredentialImporterTests` (runCommand undefined).
- [ ] **Step 3: Implement** `runCommand` per the plumbing above (nil on non-zero exit is why the third test needs the exit check BEFORE returning stdout).
- [ ] **Step 4: Green** — filter, then full `swift test`.
- [ ] **Step 5: Commit** — `git add Sources/Dreamux/Models/CLICredentialImporter.swift Tests/DreamuxTests/CLICredentialImporterTests.swift && git commit -m "Connections: generic runCommand token import (any CLI, not just gh/expo)"`

### Task 3: Freeform header template + query kind + custom-command import (AddConnectionSheet)

**Files:**
- Modify: `Sources/Dreamux/Views/AddConnectionSheet.swift`

Build-gated (no unit tests; verified by build + the manual smoke at the end). Three changes:

1. **Freeform header + query kind.** Replace `KindChoice { bearer, apiKey, basic, env }` with `KindChoice { header, basic, query, env }`:
   - `.header` shows an editable **Header name** field (`@State headerName`, default `"Authorization"`) AND an editable **Value template** field (`@State valueTemplate`, default `"Bearer {token}"`), with a caption "must contain {token}". `effectiveKind` for `.header` → `.header(headerName: headerName.trimmed, valueTemplate: valueTemplate.trimmed)`.
   - `.query` shows a **Query param** field (`@State queryParam`, default `"api_key"`) → `effectiveKind` `.query(param: queryParam.trimmed)`.
   - `.basic`/`.env` unchanged.
   - `kindFieldsValid`: `.header` requires non-empty headerName AND `valueTemplate.contains("{token}")`; `.query` requires non-empty param; basic/env as today. (This mirrors the authenticator's `.templateMissingPlaceholder` guard so a bad template can't be saved.)
   - `applyDraft`'s reverse-map: `.header(name, template)` → `kindChoice = .header; headerName = name; valueTemplate = template`; `.query(param)` → `kindChoice = .query; queryParam = param`; basic/env as today (drop the special bearer/apiKey branching — a Bearer import now just lands as `.header` with the "Bearer {token}" template, which is correct and editable).
2. **Custom-command import.** In `importSection`, below the provider Picker, add a divider + a "Or run a command" row: a `TextField` bound to `@State private var importCommand = ""` (placeholder e.g. `gh auth token`) and a **Run** `.soft` button (disabled while importing / empty). Its action runs `CLICredentialImporter.runCommand(importCommand)` in a `Task`; on a non-nil token, set `token = <result>`, `mode` stays import, show "Imported from command — review below, then Save." (leave `label`/`hosts` for the user, since a raw command has no provider metadata); on nil, show "Command produced no token." The provider-preset Import path is unchanged.
3. **Consent copy.** A one-line caption under the command field: "Runs at your privilege when you click Run — Dreamux never runs it automatically."

Keep the token `SecureField`-only and never echoed; keep `save()`/`store.add` unchanged (it already trims the token).

- [ ] **Step 1: Implement** the three changes.
- [ ] **Step 2: `swift build` + full `swift test`** (unchanged count — UI is build-gated).
- [ ] **Step 3: Commit** — `git add Sources/Dreamux/Views/AddConnectionSheet.swift && git commit -m "Connections: freeform header template + query kind + custom-command import"`

### Task 4: Bind-sheet recipe prefill + generic-import e2e

**Files:**
- Modify: `Sources/Dreamux/Views/AddConnectionSheet.swift` (accept a prefill slot)
- Modify: `Sources/Dreamux/Views/Applets/ConnectionBindSheet.swift` (pass the slot's recipe)
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift`, `Scripts/e2e/driver.py`, `Scripts/e2e/PROTOCOL.md`

**Interfaces (Consumes):** `ConnectionSlot.authKind`/`.importCommand`/`.hosts`/`.suggests` (G1); `CLICredentialImporter.runCommand` (G2); the freeform sheet (G3).

**Prefill (build-gated):**
1. `AddConnectionSheet` gains `var prefillSlot: ConnectionSlot? = nil` (defaulted — Settings call site unchanged). In `.onAppear`, BEFORE the existing `suggestedProvider` handling, if `prefillSlot` is non-nil:
   - `hostsText = prefillSlot.hosts.joined(separator: ", ")`.
   - if `prefillSlot.authKind` present, set `kindChoice` + its fields from it (same mapping as `applyDraft`'s reverse-map: `.header` → header name+template; `.query` → param; `.basic`/`.env` → their field), and switch `mode = .manual` (the recipe defines the shape, so Manual is the natural landing).
   - if `prefillSlot.importCommand` present, set `importCommand = <it>` and `mode = .importFromCLI` (so the user sees the ready-to-run command) — importCommand wins the landing tab when both are present, since running it is the fast path; the manual fields are still prefilled underneath.
   - `label` defaults to `prefillSlot.label` if empty.
   (Keep the existing `suggestedProvider` preset logic as a fallback when there's no recipe.)
2. `ConnectionBindSheet`: change the Create-new presentation from `AddConnectionSheet(store:suggestedProvider: slot.suggests, onDone:)` to `AddConnectionSheet(store:prefillSlot: slot, suggestedProvider: slot.suggests, onDone:)` (pass both; prefillSlot drives, suggestedProvider is the no-recipe fallback).

**E2E — generic command import (concrete, TLS-free):** prove `runCommand` → connection → bridge end-to-end.
- Add e2e command `importConnection {id, hosts, envVar, command}` → `let token = await CLICredentialImporter.runCommand(command)` then `ConnectionStore.shared.add(label:"probe", kind: .env(vars:[envVar]), hosts: hosts, token: token!, source: .importedFromCLI(tool:"command"), preferredID: id)` (error if runCommand returns nil). Mirrors the existing `createConnection` shape.
- Extend `scenario_connections`: after the existing checks, `importConnection {id:"cmd", hosts:["x"], envVar:"CMD_TOKEN", command:"printf cmd-tok-789"}`; bind a second env slot on the probe applet to `cmd`; the probe does `dreamux.shell.exec('printf %s "$CMD_TOKEN"', {connection:"<slot>"})` → `kv.set("cmdToken", stdout)`; assert `cmdToken == "cmd-tok-789"` — proving a command-imported token flows through the whole bridge. (Reuse the probe-rewrite + poll pattern already in the scenario.)
- `PROTOCOL.md`: document `importConnection`.

- [ ] **Step 1: Implement** the prefill + the e2e command + scenario extension.
- [ ] **Step 2: `swift build` + full `swift test`; run `python3 Scripts/e2e/driver.py connections`** — iterate to PASS (grep the real summary line, never a piped exit code).
- [ ] **Step 3: Commit** — `git add Sources/Dreamux/Views/AddConnectionSheet.swift Sources/Dreamux/Views/Applets/ConnectionBindSheet.swift Sources/Dreamux/E2E/E2ECommands.swift Scripts/e2e/driver.py Scripts/e2e/PROTOCOL.md && git commit -m "Connections: bind-sheet recipe prefill + generic-command import e2e"`

---

## Final gate (whole-feature)

- [ ] Full `swift test` green; `python3 Scripts/e2e/driver.py connections` green; re-run `applets` green (no regression).
- [ ] `./Scripts/make-app.sh debug` + launch (isolated preview) — manual pass: Settings → Add connection → **Manual** with a custom header name + editable template (e.g. `Authorization` / `token {token}`) saves; **Custom command** import (`echo my-token`) fills the token; an applet whose slot declares a recipe opens its bind sheet pre-filled.
- [ ] README: the Connections paragraph already covers the model; add one line that applets can declare their own recipe and any CLI login imports via a command.
- [ ] This is a pre-merge extension of the Connections branch — it lands with the rest on merge.

## Deferred (unchanged)

OAuth (device/redirect + refresh). Everything else in the parent spec's Deferred section.
