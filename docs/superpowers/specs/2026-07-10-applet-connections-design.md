# Applet Connections: authenticated access for applets — design

**Date:** 2026-07-10
**Status:** approved direction, spec for implementation planning
**Builds on:** `2026-07-09-app-studio-applets-design.md` (App Studio / applets)

## Problem

Applets are most useful when they show *your* data — PRs on a private repo,
your Expo builds, your Linear issues — which means they must authenticate to
external services. Three sub-cases exist, and they need different handling:

1. **CLI-backed** (`gh`, `eas`, `aws`, `gcloud`, `vercel`, `stripe`, …): the
   user has already logged the CLI in, and an applet's `shell.exec` inherits
   the user's environment and home, so `gh pr list` / `eas build:list` **work
   today with no new machinery**. This case is already solved by the shipped
   bridge; this spec only *formalizes* it.
2. **HTTP APIs with a token** (GitHub PAT, Expo token, Linear API key): the
   applet wants `http.fetch`, which needs a credential the applet must not
   hard-code or hold in plaintext.
3. **OAuth** (login flow + refresh): deferred to v2, but the abstraction here
   is designed to absorb it.

The danger to avoid: a token pasted into an applet's JS can leak — the
applet's own `http.fetch` could exfiltrate it, `console.log` could print it,
and a shared applet would carry a secret. The goal is authenticated applets
where **the secret never enters the web view**, is centrally managed and
revocable, and shared applets carry only a *declaration* of what they need.

## Concept: a Connection

A **Connection** is a named credential for a service, plus how to apply it and
where it may be sent. The secret lives in the **macOS Keychain**; everything
else is non-secret metadata.

```
Connection {
  id: String            // slug, e.g. "github", "expo-personal"
  label: String         // "GitHub (personal)"
  kind: AuthKind
  hosts: [String]       // ENFORCED allowlist of hosts the token may reach
  source: .manual | .importedFromCLI(tool) | .oauth   // provenance
  createdAt: Date
}

AuthKind =
  | .header(name: String, valueTemplate: String)  // valueTemplate contains "{token}"
  | .basic(username: String)                       // value = "Basic base64(user:token)"
  | .query(param: String)                          // append ?param={token} (legacy APIs)
  | .env(vars: [String])                           // inject each var = token into shell.exec
```

`.header` covers the common cases via its template: GitHub fine-grained/OAuth
tokens (`Authorization: Bearer {token}`), GitHub classic PATs
(`Authorization: token {token}`), custom keys (`X-API-Key: {token}`). `.basic`
and `.query` cover the stragglers; `.env` is the shell path.

**The secret itself** is a Keychain generic-password item
(`kSecClassGenericPassword`, service `com.dreamux.Dreamux.connection`, account
= the connection `id`, `kSecAttrAccessibleWhenUnlocked`). It is written once,
read only by the native bridge, and never returned to any applet.

## How an applet uses a Connection

An applet **declares slots** in its manifest (carrying no secret — so it is
marketplace-safe):

```json
"requiresCapabilities": ["http"],
"requiresConnections": [
  { "id": "github", "label": "GitHub — read your PRs",
    "hosts": ["api.github.com"], "suggests": "github" }
]
```

A slot's `id` is what the applet passes at the call site. `label` is shown at
bind time; `hosts` is the applet's *stated* intent (advisory, shown to the
user); `suggests` is an optional provider hint so the bind UI can offer
"Import from `gh`" directly. The **enforced** allowlist at call time is the
bound *Connection's* `hosts`, never the slot's.

Two call sites, both keeping the token native-side:

- **Authenticated fetch proxy** (HTTP APIs — the star):

  ```js
  const prs = await dreamux.http.fetch(
    "https://api.github.com/repos/me/private/pulls",
    { connection: "github" });
  ```
  The bridge (native): resolves the slot → bound Connection; **rejects unless
  the URL scheme is `https`** (never attach a token over cleartext); **rejects
  unless the URL host exactly matches** one of the Connection's `hosts`; reads
  the token from Keychain; applies it per `kind`; performs the request; returns
  `{status, headers, text}`. The applet never sees the token.

- **Scoped env injection** (CLI-backed, `.env` kind):

  ```js
  await dreamux.shell.exec("gh pr list --json number,title",
                           { connection: "github" });
  ```
  The bridge injects the connection's `.env` vars (e.g. `GH_TOKEN=…`) into
  **only that child process's** environment — not the applet's ambient env,
  not other execs. Unavoidably the token is in that one child process (that is
  how CLI auth works), but it never enters the web view.

Slots also expose **non-secret status** so an applet can render its own
"connect me" affordance (always allowed, like `context()`):

- `dreamux.connections.status("github")` → `{ bound: Bool, label, hosts }`
- `dreamux.connections.request("github")` → asks Dreamux to open the native
  bind sheet for that slot; resolves when the user finishes (or cancels).

## Storage & scope

- **Connections are global** (a token is a user credential, reused across
  projects). Metadata: `<stateRoot>/connections.json`
  (`ProjectStore.stateRootURL()`, `$DREAMUX_STATE_DIR`-aware). Secrets:
  Keychain, keyed by connection id.
- **Bindings are per applet instance.** Which Connection fills an applet's slot
  is stored beside its data:
  `<project>/.dreamux/appdata/<slug>/connections.json`, a map
  `slotId → connectionId`. A binding is not a secret (just a reference); it is
  also the **grant** — an applet may use a Connection only through a binding it
  was given. Removing the binding revokes access. For App Studio library
  previews, bindings live in the scratch-data dir.

This mirrors the applet code-vs-data split: the credential is shared/global,
access is scoped per applet, and a shared applet stub carries neither the
secret nor a binding.

## Native components

- `KeychainSecretStore` — a small `protocol SecretStore { get/set/delete(id:) }`
  with a Keychain-backed implementation (`import Security`) for the app and an
  **in-memory implementation for tests** (Keychain access in a test host is
  unreliable/prompting). The protocol is the seam that keeps the store unit-
  testable.
- `ConnectionStore` (`@MainActor @Observable`) — CRUD over connections
  (metadata in `connections.json`, secrets via `SecretStore`); mirrors
  `ProjectStore`'s persistence discipline.
- `ConnectionBindingStore` — reads/writes a project applet's
  `slotId → connectionId` map; resolves a slot at call time.
- `CLICredentialImporter` — per-provider recipes to import an existing CLI
  login: `gh auth token`; Expo `EXPO_TOKEN` env or `~/.expo/state.json`. Each
  recipe yields a token + a sensible default `kind`/`hosts` for a new
  Connection.
- `ConnectionAuthenticator` (pure, tested) — given a `URL`, an `AuthKind`, and
  a token, returns either the mutated `URLRequest` (header/basic/query) or the
  env additions (`.env`), or an error. Enforces **https-only** and the
  **exact-host** allowlist. This is the security-critical pure function.

The bridge (`AppletBridge`) gains `{connection}` handling inside the existing
`http.fetch` and `shell.exec` cases (still requiring the `http`/`shell`
capability *and* a resolved binding), plus the always-allowed
`connections.status` / `connections.request` methods.

## UI

- **Manage connections — Settings (⌘,).** A "Connections" pane: list; add
  (paste a token, or **Import from `gh` / `eas`**); edit label/hosts; delete
  (removes the Keychain item + metadata; any binding referencing it becomes
  "reconnect needed"). This is the one place credentials live.
- **Bind a slot — the applet host view.** When an open applet declares a slot
  with no binding, `AppletHostView`'s header shows a subtle banner —
  *"GitHub connection needed — Connect"* — opening a **bind sheet**: pick an
  existing Connection, or create one inline (paste / import-from-CLI, pre-filled
  from `suggests`), then bind. The sheet flags any Connection whose `hosts`
  don't cover the slot's stated `hosts` (the call would be rejected at runtime),
  and offers to add the missing host to the chosen Connection. Enforcement at
  call time is always the Connection's `hosts`, never the slot's. Same sheet is
  reachable from `dreamux.connections.request(slot)`.
- Adopting/creating an applet that declares connections surfaces the same
  banner immediately, so the "wire up your own credential" step is obvious and
  per-user.

## Security posture

Consistent with App Studio's framing: applets are user-commissioned (a consent
seam, not an adversarial sandbox). Connections do **not** claim to defend
against a hostile applet you granted `shell` to — such an applet can already
read ambient env and CLI credential stores. What Connections provide:

- **Token never enters JS** for the HTTP case (proxy attaches it natively).
- **https-only + exact-host allowlist**, enforced natively per request, so a
  token can't be redirected to an attacker host or sent in cleartext. Host
  match is a case-insensitive exact comparison of the URL host — **not** a
  suffix match (`api.github.com.evil.com` must fail).
- **Central management + revocation** — one place to see and delete every
  credential; deleting invalidates every applet's access at once.
- **Marketplace-safe** — shared applets carry slot declarations, never secrets
  or bindings.
- **Redaction** — tokens never appear in logs/signals; any request logging
  redacts the `Authorization`/credential header and the `.query` token.

Keychain items key on the app's code signature: on an ad-hoc-signed dev build
that is rebuilt constantly, the OS may prompt on access after a rebuild (the
same signature-stability issue as TCC). A Developer-ID-signed `/Applications`
build makes them stick — another reason the Developer-ID signing/notarization
roadmap matters.

## Testing

- **Unit:** `Connection`/`AuthKind` codable round-trip; `ConnectionStore`
  reconciliation against `connections.json`; `SecretStore` in-memory impl
  round-trip; binding resolution (slot → connection, unbound → error);
  `CLICredentialImporter` recipe parsing (given fixture `gh`/`eas` output).
- **Security-critical pure tests (`ConnectionAuthenticator`):** exact-host
  allowlist (`api.github.com` matches; `api.github.com.evil.com`,
  `evil.com?api.github.com`, `apiXgithub.com`, and a bare-IP host all reject);
  https-only (an `http://` URL rejects with no header attached); each `kind`
  produces the correct header/basic/query/env output with `{token}`
  substituted and nothing leaked into the URL path.
- **E2E:** a fixture applet, bound to a test Connection, does
  `http.fetch(<local echo server>, {connection})`; the driver asserts (via the
  applet writing the result to `kv`) that the echoed request carried the
  expected `Authorization` header — and that a `fetch` to a **non-allowlisted
  host** is rejected with **no** auth header sent. The echo server is local
  (no real network, no real secret; the token is a fixture string in the test
  Keychain/in-memory store).

## Deferred (designed-for, not built)

1. **OAuth connections** (device-code / redirect flow, token + refresh managed
   by Dreamux, auto-refresh on 401) — `AuthKind`/`source` already leave room;
   a bound OAuth connection presents to the proxy as a `.header` bearer.
2. **Raw-token escape hatch** (`dreamux.secrets.get(slot)` returning the token
   to JS for services the proxy can't model) — deliberately **out** of v1;
   would be a loudly-marked, separately-granted capability.
3. **Wildcard/subdomain host rules** (`*.expo.dev`) — v1 is exact-host only;
   add opt-in wildcarding later if a real service needs it.
4. **Connection health/expiry surfacing** and per-connection scope display.
5. **Marketplace connection templates** — sharing "needs a GitHub connection
   to api.github.com" (provider + hosts, no secret) as part of an applet stub.

## Key integration seams

- Manifest: add `requiresConnections: [ConnectionSlot]` to `AppletManifest`
  (`Models/AppletManifest.swift`), tolerated-optional so older applets decode.
- Bridge: `{connection}` handling in `http.fetch` / `shell.exec` and the new
  `connections.status` / `connections.request` methods
  (`Views/Applets/AppletBridge.swift`, `AppletBridgeCore` for gating).
- Stores: `ConnectionStore` + `KeychainSecretStore` (App Support / Keychain,
  mirroring `ProjectStore`); `ConnectionBindingStore` over
  `.dreamux/appdata/<slug>/connections.json`.
- Import: `CLICredentialImporter` reuses `AppletShell`/`GhOperations`-style
  process invocation.
- UI: a Connections pane in `SettingsView`; a bind banner + sheet in
  `AppletHostView`.
- Author docs: extend `Resources/AppletScaffold/APPLET.md` with the
  connections section (slots, `{connection}` on fetch/exec, status/request).
