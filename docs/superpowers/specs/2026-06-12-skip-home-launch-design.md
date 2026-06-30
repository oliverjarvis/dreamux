# Skip Home at Launch + Project Management in the Rail

**Date:** 2026-06-12
**Status:** Approved

## Problem

Launching Dreamux shows the Home window (project grid) and requires a
click before reaching the real workspace. The `ProjectsRail` inside the
project window already lists every project, switches between them, opens
new windows, and tears off via drag — so for a returning user the Home
grid is pure friction. Home's only unique responsibilities today are
project creation (`CreateProjectSheet` with the clone/init/import repo
bootstrap), project deletion (move to trash with confirmation), and the
zero-project empty state.

## Decision

Stop showing Home by default. Launch lands directly in the last-used
project window. Project creation and deletion move into the rail so the
day-to-day loop never needs Home. Home survives only as the
zero-project/first-run screen, still reachable deliberately via the
rail's Home row and ⇧⌘0.

Approaches considered:

- **A — launch redirect only:** smallest change but Home remains the
  only create/delete surface, so users still bounce through it.
- **B — launch redirect + rail creation/deletion (chosen):** the rail
  becomes self-sufficient; Home demotes to onboarding.
- **C — remove Home entirely:** requires an awkward project-less state
  inside a window hierarchy keyed by project UUID; most work for little
  extra benefit over B.

## Design

### 1. Launch redirect (Home → last project)

- `ProjectWindowContents.onAppear` records the project's ID to
  UserDefaults under `lastOpenedProjectID`. This covers every path a
  project window appears or switches through (open from Home, rail
  switch, tear-off window); last writer wins.
- `HomeView.task` gains a one-shot launch redirect. On the first Home
  presentation per process: refresh the store, and if any projects
  exist, open the resolved project window and dismiss Home — the same
  `openProject` mechanism the e2e auto-open already uses.
- Resolution order: remembered `lastOpenedProjectID` if it still
  resolves in the store; otherwise the first project in store order.
- The redirect is guarded by a process-lifetime one-shot flag so
  "Show Home" (⇧⌘0) and the rail's Home row present Home normally
  without bouncing back to a project.
- Deployment target is macOS 14, so `.defaultLaunchBehavior(.suppressed)`
  (macOS 15) is unavailable; the redirect-from-`.task` approach is the
  supported pattern and already has precedent in this codebase.
- **E2E:** when `E2EMode.isActive`, the redirect is suppressed unless
  `E2EMode.autoOpenProjectName` is set (existing behavior takes
  precedence). Existing scenarios that script the home grid keep
  working unchanged.
- **Zero projects:** Home stays up showing the existing empty state.

### 2. New Project from the rail

- Extract `CreateProjectSheet` plus the creation flow
  (`createProject`, `pendingRepoIntent`, `runRepoIntent`) from
  `HomeView` into a reusable component, e.g.
  `Views/CreateProjectFlow.swift`, parameterized by `ProjectStore` and
  an `onCreated(Project)` callback. `HomeView` consumes the same
  component so the two surfaces cannot drift.
- `ProjectsRail` gets a "＋ New Project" row pinned below the scrolling
  project list, styled like `HomeRailRow`, presenting the shared sheet.
- On success the current window switches to the new project via the
  rail's existing `onSelect` path.

### 3. Move to Trash from the rail

- `ProjectRowView`'s AppKit context menu gains "Move to Trash…",
  threaded out through a new `onDelete` callback on `ProjectRow`.
- `ProjectsRail` owns the confirmation alert (same wording as Home's:
  folder moved to Trash, recoverable from Finder).
- Deleting the project the current window is showing: switch the window
  to the first remaining project via `onSelect`. Deleting the last
  project: open Home and dismiss the project window.

### 4. Home demoted, not removed

No functionality is deleted — creation/deletion are relocated onto the
rail and Home keeps working as before for the zero-project first-run
case and deliberate visits.

## Error handling

- Creation errors surface inside the shared sheet exactly as they do on
  Home today (`createError` text, `isCreating` spinner).
- Deletion errors reuse Home's "Couldn't delete project" alert pattern,
  owned by whichever surface initiated the delete.
- A stale `lastOpenedProjectID` (project deleted outside the app) falls
  back silently to the first project; no error UI.

## Testing

- Unit test the last-opened resolution logic (remembered ID valid,
  stale, store empty) — extract it into a small pure helper so it is
  testable without UI.
- E2E default behavior is unchanged (redirect suppressed under
  `E2EMode`), so existing scenarios pass as-is. The rail's create and
  delete flows reuse logic already covered via Home; add an e2e
  scenario for rail-created projects only if the harness can assert on
  window/sheet state cheaply.
