# Applet Connections — generalization (any auth, applet-declared) — design addendum

**Date:** 2026-07-10
**Status:** approved direction, spec for implementation planning
**Builds on:** `2026-07-10-applet-connections-design.md` (which this extends, same branch, pre-merge)

## Problem

The shipped Connection machinery is already generic under the hood — the
`AuthKind` model (header / basic / query / env) + host allowlist applies a
credential to *any* service — but three things make it *feel* service-specific
and block genuinely ad-hoc use:

1. **Import-from-CLI is a fixed `gh`/`expo` list.** A CLI-backed login for any
   other tool (`vercel`, `doppler`, `op`, `aws`, …) can't be one-click imported.
2. **The manual editor locks the header value template.** "Bearer header" is
   hard-wired to `"Bearer {token}"` and "API-key header" to raw `"{token}"`; a
   scheme like `Authorization: token {token}` (GitHub classic) or any custom
   prefix can't be entered, and `.query` auth (in the model) has no UI at all.
3. **Applets can only *hint* a provider** (`suggests: "github"`), not declare
   the exact auth shape their service needs — so adopting a "Linear" or
   internal-API applet still means the user hand-builds the connection.

Goal: make **token-based auth fully ad-hoc** — the applet declares what it
needs, the user supplies only the secret, and Dreamux hardcodes nothing
service-specific (`gh`/`expo` become built-in *presets*, not the ceiling).
**OAuth stays deferred** (a different mechanism — device/redirect + refresh;
most dev APIs offer a PAT).

## Changes

### 1. Applet-declared connection recipe

Extend the manifest `ConnectionSlot` with two **optional** fields (secret-free,
so still marketplace-safe; back-compatible — synthesized `Codable` auto-nils
absent optionals, so old manifests/slots decode unchanged):

```swift
struct ConnectionSlot: Codable, Equatable, Sendable {
    let id: String
    var label: String
    var hosts: [String]
    var suggests: String?        // kept — provider hint for the import preset
    var authKind: AuthKind?      // NEW — the exact auth shape the service needs
    var importCommand: String?   // NEW — a suggested command that prints the token
}
```

An applet author (the build agent) declares, e.g.:

```json
"requiresConnections": [
  { "id": "linear", "label": "Linear API key", "hosts": ["api.linear.app"],
    "authKind": { "header": { "headerName": "Authorization", "valueTemplate": "{token}" } } },
  { "id": "gh", "label": "GitHub", "hosts": ["api.github.com"],
    "authKind": { "header": { "headerName": "Authorization", "valueTemplate": "Bearer {token}" } },
    "importCommand": "gh auth token" }
]
```

When a slot carries a recipe, the bind sheet's **Create-new** path pre-fills
kind + hosts (from `slot.hosts`) + the import command; the user supplies only
the secret. Dreamux fulfils it generically — nothing service-specific in the
app. A recipe-less slot behaves exactly as today (generic Create-new).

### 2. Freeform manual auth

`AddConnectionSheet` manual mode gains:

- An **editable header value template** (default `"Bearer {token}"`), required
  to contain `{token}` — the same invariant `ConnectionAuthenticator` already
  enforces (`.templateMissingPlaceholder`), validated in the sheet so a bad
  template can't be saved.
- A **Query-param** kind (a `param` field → `.query(param:)`).

Bearer / API-key remain quick presets that pre-fill the freeform header
name+template; "Custom header" exposes both fields raw. So any static scheme —
custom prefix, raw key, key-in-query — is now typeable by hand.

### 3. Generic "import from a command"

Import mode gains **"Custom command"**: any command that prints a token on
stdout; Dreamux runs `/bin/sh -lc <cmd>`, trims stdout, uses it as the token.
`gh`/`expo` become built-in presets expressed over this same mechanism
(`gh` → `importCommand: "gh auth token"`; expo → its token read). `providers`
stays as the curated preset list; the generic path handles everything else.

**Consent (load-bearing rule):** an `importCommand` — whether typed by the user
or carried in an applet's slot recipe — is shell run at user privilege. It is
**always shown to the user and executed ONLY on the user's explicit click**,
never auto-run on adopt/open/bind. This preserves the App Studio consent seam:
an applet may *suggest* a token-fetch command, but the user sees it and
triggers it (identical trust to `shell.exec`, which the applet already has if
it declares `shell`).

## Security

- The freeform template is inert data → the credential is still applied only
  through `ConnectionAuthenticator` (https-only, exact-host, placeholder-
  required). No new attach surface; the redirect guard still applies.
- The recipe carries **no secret** — marketplace-safe.
- `importCommand` runs visibly, on user click, at user privilege — same trust
  model as the already-granted `shell` capability. **Never auto-executed.**
- Connection ids are still `slugify`'d at construction (unchanged chokepoint).

## Deferred (unchanged from the parent spec)

OAuth connections (device/redirect flow + token refresh) — the one remaining
auth class; the `AuthKind`/`Source` model already reserves room, and a bound
OAuth connection would present to the proxy as a `.header` bearer.

## Testing

- **Unit:** `ConnectionSlot` decodes with and without the new optional fields
  (back-compat) and round-trips a full recipe; `CLICredentialImporter.runCommand`
  captures + trims a command's stdout (fixture command) and returns nil on
  empty/failure; the freeform template's `{token}`-required validation.
- **E2E:** a probe applet whose manifest *declares* a custom-header recipe +
  an env `importCommand`; the driver binds it and asserts (on disk, via kv) the
  declared header shape reaches the request (extending the existing
  `scenario_connections` shell/http/status proof) — no service-specific code.

## Integration seams

- `Models/Connection.swift` — `ConnectionSlot` + `authKind?`/`importCommand?`.
- `Models/CLICredentialImporter.swift` — `runCommand(_:) async -> String?`;
  `gh`/`expo` presets expressed as `importCommand`s.
- `Views/AddConnectionSheet.swift` — editable template + Query kind + Custom-
  command import.
- `Views/Applets/ConnectionBindSheet.swift` — prefill Create-new from the
  slot's recipe; show + user-trigger `importCommand`.
- `Resources/AppletScaffold/APPLET.md` — document the recipe fields
  (`authKind`, `importCommand`) and that import commands are user-consented.
- `Scripts/e2e/driver.py` + `E2ECommands.swift` — extend `scenario_connections`
  with a declared-recipe applet.
