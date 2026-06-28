# Remove the Home screen

## Problem

The app has two "Home" surfaces that both render a grid of project cards:

1. **In-window Home** — a `Home` row at the top of the project sidebar
   (`ProjectsRail`) that swaps the project window's detail pane to a project
   grid (`ContentView.showingHome`). This duplicates the project list sitting
   directly below it in the same sidebar.
2. **Standalone Home window** — `Window(id: "home")`, reachable via ⇧⌘0. On a
   normal launch a one-shot redirect jumps straight into the last-opened
   project, so this window is only seen at zero projects (first run) or as the
   delete-last-project fallback.

Both are redundant now that the sidebar lists and switches projects. We are
removing **both** surfaces.

## Goal

Eliminate every Home surface while preserving the roles Home quietly played:
landing somewhere sensible on launch, creating the first project when none
exist, recovering when the bound project vanishes, and the e2e auto-open
contract.

## Approach

A single `WindowGroup("Project", id: "project", for: UUID.self)` becomes the
only scene. At launch SwiftUI opens one window with `projectID == nil`; a
**launch gate** resolves where to land and rewrites the binding in place. No
second window, no open/dismiss dance.

### Scene structure (`ClayspaceApp`)

Delete the `Window(id: "home")` scene and `HomeCommands`' "Show Home"/⇧⌘0.
Move the surviving "Notification Settings…" command onto the project scene's
commands. The `WindowGroup` builder delegates to a new `ProjectRootView`:

- `projectID` resolves to a live project → `ProjectWindow` (unchanged).
- `projectID == nil` → `LaunchGate`.
- `projectID != nil` but the project is missing → `MissingProjectView`
  (project deleted out from under this window). Its button routes through the
  launch gate instead of "Back to Home".

### LaunchGate

On appear, resolves a destination and acts:

1. If `E2EMode.autoOpenProjectName` matches a project → set `projectID` to it.
   (Preserves the `CLAYSPACE_E2E_AUTOOPEN` contract — the lookup simply moves
   here from `HomeView.task`.)
2. Otherwise `LaunchDestination.resolve(lastOpenedID:projects:)`:
   - `.project(id)` → set `projectID = id` (routes straight into the project).
   - `.welcome` → render `WelcomeView`.

Routing rewrites the same window's binding, so the window re-renders as the
project. The one-shot "did I already redirect" machinery is deleted — with no
Home to return to, re-resolving a `nil` window is always correct (e.g. macOS
reopen lands back in the last project).

### WelcomeView (new)

Minimal zero-projects / first-run landing. Folder icon, "No projects yet", a
short blurb, and a **Create Project** button → `CreateProjectSheet` → on create
sets `projectID` to the new project. It does **not** list projects (there are
none). This replaces `HomeView`'s empty state; the rest of `HomeView` (the grid,
`ProjectCard`, redirect machinery) is deleted outright.

### ContentView

Remove `showingHome`, the detail-pane Home overlay (`ZStack`/`HomeView`), both
`showingHome = false` resets, and the `$showingHome` argument to `ProjectsRail`.
Simplify `navigationTitle`/`navigationSubtitle` to just the current project. The
e2e `sidebarMode` bridge sync stays.

### ProjectsRail

- Drop the `Home` `Label` row and collapse `SidebarItem` to a plain `UUID`
  selection (the enum's only other case was `.home`).
- Remove the `@Binding showingHome`.
- Delete-last-project fallback: set the window's binding to `nil` (→ `LaunchGate`
  → `WelcomeView`) instead of `openWindow(id: "home")` + `dismissWindow`. Remove
  the now-unused `dismissWindow`.
- `onSelect` widens to `(UUID?) -> Void` so the rail can clear the window.

### ProjectWindow

- Remove the `HomeView.disarmLaunchRedirect()` call.
- `onSwitchProject` widens to `(UUID?) -> Void`; the `WindowGroup`'s
  `{ projectID = $0 }` already type-checks against the `UUID?` binding.
- `LastOpenedProject.record(...)` stays — still drives launch routing.

### LaunchDestination

Rename the `.home` case → `.welcome`. "Home" is gone as a concept; a `.home`
case would be stale terminology. `resolve(...)` returns `.welcome` for an empty
store, `.project(id)` otherwise (logic unchanged).

### Docs

Update the `CLAYSPACE_E2E_AUTOOPEN` row in `Scripts/e2e/PROTOCOL.md`: the name
is now resolved by the launch gate, not "the Home view".

## Components / boundaries

- `LaunchGate` — *what*: pick where a project-less window lands; *use*: rendered
  by `ProjectRootView` when `projectID == nil`; *deps*: `ProjectStore`,
  `LaunchDestination`, `E2EMode`, the `projectID` binding.
- `WelcomeView` — *what*: invite the user to create their first project; *use*:
  rendered by `LaunchGate` when there are no projects; *deps*: `ProjectStore`,
  `CreateProjectSheet`, the `projectID` binding.
- `ProjectRootView` — *what*: route a window between project / launch gate /
  missing-project; *use*: the `WindowGroup` builder; *deps*: `ProjectStore`, the
  `projectID` binding.

## Testing

- **Unit:** update `LaunchDestinationTests` for the `.home` → `.welcome` rename
  (`testEmptyStoreLandsOnHome` → `…Welcome`). `resolve` logic and
  `LastOpenedProject` round-trip tests are otherwise unchanged.
- **Build:** `./Scripts/make-app.sh debug` must compile with no references to
  the deleted symbols.
- **Manual (per the `run` skill):** launch the bundle and confirm it lands in a
  project window directly — no Home grid, no `Home` row in the sidebar.
- **e2e:** `CLAYSPACE_E2E_AUTOOPEN` still opens the demo project window at
  launch (the driver waits on `project window for <name>`), so
  `Scripts/e2e/run-e2e.sh` should pass unchanged.

## Out of scope

- Re-binding ⌘N to "New Project" globally (creation stays in the rail's New
  Project bar plus Welcome).
- Any other sidebar/source-list simplification — this spec is only about Home.

## Behavior preserved

Normal launch lands in the last-opened project; e2e auto-open works; project
creation lives in the rail (and Welcome at zero projects). The only user-visible
loss is the redundant project grid and ⇧⌘0 — the intent of the change.
