# Quit guard — confirm ⌘Q only when work is running — design

Dreamux hosts live terminals and agent runs, so a stray ⌘Q — muscle memory
aimed at an embedded terminal, or a mistyped chord — kills every session
with no warning. This adds the Terminal.app-style guard: quitting is
instant when the app is idle, and shows one native confirmation alert when
work is actually in flight.

## Problem

`terminate:` currently goes straight through: AppKit's default
`applicationShouldTerminate` answer is "now". On 2026-07-10 the app was
killed mid-session by a key equivalent dispatching `terminate:` (unified
log: `performKeyEquivalent:` → `sendAction:` → `terminate:`) — the second
accidental quit in a week. Quitting tears down every PTY (zsh and whatever
runs inside it, including interactive Claude sessions) and every
RunnerManager child process.

## Behavior

- **Idle** — ⌘Q / Quit menu / Dock quit behaves exactly as today: the app
  terminates immediately, no dialog.
- **Busy** — a native `NSAlert` appears:
  - Message: **Quit Dreamux?**
  - Informative text: counts of what dies, e.g. "2 runs and 1 busy
    terminal will be terminated." (singular/plural handled; only non-zero
    kinds listed).
  - Buttons: **Cancel** (default — Return and Esc both keep the app
    alive, so a panicked double-tap can't quit) and **Quit**.
- **E2E mode** — when `E2EMode.socketPath` is set the guard is bypassed
  entirely; automated runs must never hang on a modal.

## What counts as busy

1. **A run in flight** — any `RunnerManager` process with
   `isRunning == true`. These are child processes the app owns; quitting
   kills the whole process group (Foundation.Process signals its pgroup).
2. **A busy terminal** — any live `PTYShellSession` whose foreground
   process group differs from the shell's: `tcgetpgrp(masterFD) !=
   childPID`. An idle prompt does not count. This is Terminal.app's own
   heuristic, evaluated lazily only at quit time — no polling.

Not counted (deliberately, YAGNI): applet dev servers already detached
from sessions, WebKit views, unsaved editor state (editors autosave).

## Architecture

Three small pieces:

- **`QuitGuard`** (new, `Sources/Dreamux/Shell/QuitGuard.swift`, ~60
  lines): a thread-safe registry singleton. Registrants conform to a tiny
  protocol (`QuitGuardSource`) with one requirement:
  `var busyWork: BusyWork { get }` where
  `struct BusyWork { var runs: Int; var busyTerminals: Int }`.
  `busySummary()` walks live registrants, sums the counts, and returns
  `nil` (idle) or a human-readable summary for the alert.
  Registrations are weak so a forgotten unregister can't pin objects or
  phantom-block quit.
  - `RunnerManager` registers in `init` (it lives per-`ProjectSession`);
    reports its `isRunning` process count.
  - `PTYShellSession` registers when it spawns and unregisters when the
    child exits; reports busy when `tcgetpgrp` says a job owns the
    foreground.
- **`AppDelegate`** (new, in `DreamuxApp.swift`): `NSApplicationDelegate`
  implementing `applicationShouldTerminate` — returns `.terminateNow`
  when idle, when in e2e mode, or when the user confirms; otherwise
  `.terminateCancel`. Wired via `@NSApplicationDelegateAdaptor` (the app
  has no delegate today, so nothing collides).
- **Foreground-check seam** — the `tcgetpgrp` comparison lives behind an
  injectable closure (default: real syscall) so unit tests exercise
  busy/idle logic without a real PTY.

## Testing

- **Unit** (`Tests/DreamuxTests/QuitGuardTests.swift`): registration and
  weak-release lifecycle; idle → nil summary; counts and wording for
  runs-only, terminals-only, mixed; a fake source flipping busy state.
- **Manual verification** (per superpowers:verification-before-completion):
  idle quit is instant; `sleep 100` in a terminal → alert appears, Cancel
  keeps the app and the sleep alive, Quit terminates; a running run
  triggers the alert too.
- **E2E**: existing e2e scenarios keep passing — they quit the app
  programmatically and must not stall (guard bypassed in e2e mode).
