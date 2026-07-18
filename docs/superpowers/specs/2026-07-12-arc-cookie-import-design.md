# Import logins from Arc (browser cookie import) — Design

**Date:** 2026-07-12
**Status:** Approved (brainstorm complete)

## Problem

The in-app browser (`WebTabSession` / `WebTabView`, a plain `WKWebView`
on WebKit's default persistent data store) starts every session logged
out. A user who lives in Arc has to re-authenticate to their own dev
app, dashboards, and SaaS tools inside Dreamux even though those sessions
already exist in Arc. We want a one-click "import your logins from Arc"
that copies Arc's cookies into the in-app browser so the user lands
already signed in.

"Cookies" is the right unit: it carries the logged-in session for the
large majority of sites. It is not everything (see Out of scope).

## Decisions made during brainstorming

- **Source: Arc only** for v1. Arc is Chromium-based, so its cookies sit
  in a SQLite DB with values encrypted under a key in the login Keychain
  — readable with the same `SecItem` + `SQLite3` patterns already in this
  app. Safari is a deliberate follow-up (its jar is TCC-protected inside
  a container and needs Full Disk Access + a `binarycookies` parser).
- **Scope: the whole cookie jar** (all sites), not per-site. One click,
  no picker. Merged across all Arc profiles found (`Default`, `Profile
  N`) — most users have one, and merging is strictly more complete.
- **Trigger: a one-time offer + a re-runnable manual action.** A
  dismissible banner the first time the in-app browser opens, plus an
  "Import from Arc…" action that can be run again anytime.
- **Approach: one in-process pipeline behind a thin `BrowserCookieSource`
  seam** (approved over an Arc-only concrete type; the ~10-line protocol
  lets Safari/Chrome slot in later without a rewrite, and Safari is a
  known follow-up). Rejected an XPC/helper-process design as overkill for
  an unsandboxed single-user tool.
- **Consent: the macOS Keychain prompt is the gate.** Reading Arc's
  `Arc Safe Storage` key triggers the system authorization prompt; that
  is the user's explicit consent. The banner copy sets the expectation.

## Constraints & background

- **Unsandboxed app.** No `com.apple.security.app-sandbox` entitlement
  anywhere in the project. This is what makes reading another app's
  Keychain item and Application Support files possible at all. **This
  feature and App Store sandboxing are mutually exclusive** — already
  ruled out on the distribution roadmap, restated here so it is not
  re-opened by accident.
- **Shared data store.** Every `WebTabSession` builds its `WKWebView`
  with a default `WKWebViewConfiguration()`, i.e. `WKWebsiteDataStore
  .default()`. Cookies are shared across all tabs and all workspaces and
  persist across launches, so **one import covers the whole app** and
  there is no per-workspace store to fan out to.
- **Existing patterns to reuse:** `SQLiteSignalStore.swift`
  (`sqlite3_open_v2` read path), `KeychainSecretStore` in
  `SecretStore.swift` (`SecItem` query shape), and `CryptoKit` (already
  imported). AES-128-CBC + PBKDF2 are not in CryptoKit, so the decryptor
  pulls `CCCrypt` / `CCKeyDerivationPBKDF` from **`CommonCrypto`**, which
  ships with the macOS SDK (no new package dependency).

## 1. Engine-neutral cookie model + source protocol

New file `Sources/Dreamux/Browser/BrowserCookieSource.swift`:

- `struct ImportedCookie` — engine-neutral: `domain`, `name`, `value`,
  `path`, `expires: Date?`, `isSecure`, `isHTTPOnly`, `sameSite:
  HTTPCookieStringPolicy?`, `hostOnly: Bool`. No WebKit or Chromium types
  leak across this boundary.
- `protocol BrowserCookieSource` — `var displayName: String { get }`,
  `var isAvailable: Bool { get }` (does this browser's data exist on
  disk?), `func readCookies() throws -> [ImportedCookie]`.
- `enum CookieImportError: LocalizedError` — `sourceUnavailable`,
  `keychainDenied`, `keychainKeyMissing`, `databaseUnreadable(String)`,
  with user-facing `errorDescription`s.

Only `ArcCookieSource` conforms in v1.

## 2. Arc source

New file `Sources/Dreamux/Browser/ArcCookieSource.swift` —
`struct ArcCookieSource: BrowserCookieSource`. Owns all Arc-specific
knowledge and composes the two helpers below.

- `displayName = "Arc"`.
- `isAvailable` — true iff at least one Arc profile dir with a `Cookies`
  file exists under `~/Library/Application Support/Arc/User Data/`.
- `readCookies()` — for each profile, read rows via `ArcCookieDatabase`,
  decrypt each value via `ArcCookieDecryptor`, map to `ImportedCookie`,
  drop expired and undecryptable entries, merge across profiles.

**Profile discovery.** Base dir `~/Library/Application Support/Arc/User
Data/`. Profiles are subdirectories containing a `Cookies` file —
`Default` and any `Profile N`. (Arc "Spaces" share a profile's cookie
store, so no special handling.)

### 2a. `ArcCookieDatabase`

New file `Sources/Dreamux/Browser/ArcCookieDatabase.swift`.

- Arc holds a lock on the live `Cookies` DB, so **copy first**: copy
  `Cookies` (+ any `-wal` / `-shm` siblings) into a temp dir, open the
  copy `SQLITE_OPEN_READONLY` via the `SQLite3` C API (mirror
  `SQLiteSignalStore`'s open/step/finalize discipline), delete the temp
  copy when done.
- Query the Chromium `cookies` table:
  `host_key, name, encrypted_value, path, expires_utc, is_secure,
  is_httponly, samesite`.
- Yields `[ArcCookieRow]` — raw columns, `encrypted_value` as `Data`,
  no decryption here.
- **Epoch conversion:** `expires_utc` is microseconds since
  1601-01-01 UTC. `Date = (expires_utc / 1_000_000) - 11_644_473_600`
  seconds since the Unix epoch. `expires_utc == 0` → session cookie
  (`expires = nil`).
- **`samesite` mapping:** Chromium int `-1/0` → none/unspecified,
  `1` → Lax, `2` → Strict.

### 2b. `ArcCookieDecryptor`

New file `Sources/Dreamux/Browser/ArcCookieDecryptor.swift`. Pure and
unit-testable: given a Keychain key and a ciphertext blob it returns
plaintext; no I/O beyond the one Keychain read.

- **Key:** `SecItemCopyMatching` for `kSecClassGenericPassword` with
  service `"Arc Safe Storage"`, account `"Arc"`. This read raises the
  macOS authorization prompt. `errSecItemNotFound` →
  `keychainKeyMissing`; `errSecAuthFailed` / user cancel →
  `keychainDenied`.
- **Derive:** `CCKeyDerivationPBKDF(PBKDF2, password, salt="saltysalt",
  rounds=1003, PRF=SHA1, keyLen=16)` → 128-bit AES key.
- **Decrypt a value:** strip the 3-byte version prefix.
  - `v10` → AES-128-**CBC**, IV = 16 bytes of `0x20` (space), via
    `CCCrypt`; strip PKCS7 padding. Newer Chromium also prefixes a
    32-bit SHA-256 domain hash inside the plaintext — detect and strip
    when present.
  - Any other prefix (e.g. app-bound `v20`, or GCM variants) →
    `throw`/`nil` for that value → **skipped and counted**, not fatal.

## 3. Import service

New file `Sources/Dreamux/Browser/CookieImportService.swift` —
`@MainActor final class CookieImportService`.

- `func availableSource() -> BrowserCookieSource?` — returns
  `ArcCookieSource()` when `isAvailable`, else nil. Drives banner
  visibility and the manual action's enabled state.
- `func importCookies(from:) async -> ImportSummary` — calls
  `readCookies()` off the main actor, maps each `ImportedCookie` to an
  `HTTPCookie`, and injects via `WKWebsiteDataStore.default()
  .httpCookieStore.setCookie(_:)`. Returns
  `ImportSummary(imported: Int, skipped: Int, failed: Int, error:
  CookieImportError?)`.
- **One-time flag:** `hasOfferedArcImport` in `UserDefaults`. Set when
  the banner is dismissed **or** a successful import completes. **Not**
  set when the import errors before injecting anything (e.g. Keychain
  denied), so the user can retry.

`ImportedCookie` → `HTTPCookie` mapping lives here (bidirectional-free,
one direction): `.domain` keeps a leading dot when `!hostOnly`,
`.secure`/`.expires`/`.path`/`.name`/`.value` map directly, `sameSitePolicy`
set when known. Cookies that `HTTPCookie(properties:)` rejects count as
`failed`.

## 4. UI

Touch `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift`
(`WebTabView`, line ~218).

- **Banner.** A dismissible strip above the browser body (below the
  address bar), shown only when
  `CookieImportService.availableSource() != nil && !hasOfferedArcImport`:
  *"Import your logins from Arc? macOS will ask permission to read Arc's
  saved key."* Buttons **Import** / **Not now**. **Not now** sets the
  flag and hides the banner. **Import** runs the service, shows inline
  progress, then a result toast; on success the banner goes away.
- **Manual action.** An "Import from Arc…" control next to the existing
  "open externally" (`safari`) button in the bar, enabled only when a
  source is available. Runs the same service path; re-runnable anytime.
  Mirror the same action into Settings (`ConnectionsSettingsView` or a
  sibling section) for discoverability.
- **Result toast.** "Imported N logins from Arc" (or "N imported, M
  skipped"); on error, the `CookieImportError.errorDescription`.

Banner styling follows the app's row/wash conventions (see CLAUDE.md UI
notes) — generous type, no rules under headers, native-feeling controls.

## 5. Error handling

- Arc not installed → `isAvailable == false`; banner never shows, manual
  action disabled with a tooltip.
- Keychain denied / cancelled → `keychainDenied`; abort cleanly, flag
  **not** set, toast explains and invites retry.
- DB locked → avoided by copy-first; if the copy itself fails →
  `databaseUnreadable`, reported, aborted.
- Individual value undecryptable (app-bound `v20`, GCM, corrupt) → skip +
  count; import the rest.
- Expired cookies (`expires < now`) → skipped (never inject dead
  sessions).
- Malformed row / `HTTPCookie` rejects it → counted as `failed`,
  continue.

## 6. Testing

- `ArcCookieDecryptor` (unit): construct a ciphertext with the same
  PBKDF2/AES-CBC params from a known key + plaintext, assert round-trip;
  version-prefix handling (`v10` decrypts, unknown prefix →
  skipped/throws); domain-hash-prefix stripping.
- Chromium epoch → `Date` conversion (incl. `0` → session cookie) and
  `samesite` int → policy mapping (pure, table-driven).
- `ArcCookieDatabase` (unit): build a fixture SQLite file with the
  Chromium `cookies` schema + sample rows (mirrors how `SQLiteSignalStore`
  is tested), read them back; verify copy-first leaves the source
  untouched.
- `ImportedCookie` → `HTTPCookie` mapping: host-only vs leading-dot
  domain, secure, httpOnly, sameSite, expiry, session cookie.
- Service (integration): inject into an **ephemeral** `.nonPersistent()`
  `WKWebsiteDataStore` and assert cookies land + summary counts are
  right. A fake `BrowserCookieSource` drives the happy path (the real
  Keychain prompt can't run headless).
- `isAvailable` and the one-time-flag transitions (dismiss vs success vs
  error-before-inject).
- Full unit + e2e suites as regression. E2e drives the banner UI with a
  fake source injected via the existing `$DREAMUX_*` env-override pattern
  (as `SecretStoreFactory` does), so no real Arc/Keychain is touched.

## Out of scope

- **Cache.** HTTP disk caches are opaque, engine/version-specific, and
  rebuild themselves — no import path, low value. Explicitly not imported.
- **Safari.** Deliberate follow-up; needs Full Disk Access + a
  `binarycookies` parser. The `BrowserCookieSource` seam is where it
  lands.
- **localStorage / IndexedDB / saved passwords.** WebKit exposes no
  injection API for web storage; passwords are a separate Keychain-autofill
  concern. Some SPA-style sites that keep auth in localStorage will still
  need a re-login — the banner/toast copy should not over-promise.
- **App-bound (`v20`) encrypted values.** Skipped, not decrypted.
- **Ongoing sync.** This is a one-shot import, not a live mirror of Arc.

## Known fragility

Arc's on-disk layout, the `cookies` schema, and the `v10` scheme are
undocumented and can change with Arc/Chromium updates. All of that
knowledge is isolated in `ArcCookieSource` + its two helpers, so a break
is contained to one place and degrades to "N skipped" rather than a crash.
