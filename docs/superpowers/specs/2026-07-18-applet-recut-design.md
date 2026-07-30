# Applet recut — design (2026-07-18)

## Model
An applet is a **standalone artifact** (own manifest, own lifecycle,
never a worktree, never merged) that projects hold **adaptations** of —
the VS Code-extension / Raycast model. Library artifact + per-project
adopted instance. Pitch: "Raycast for your codebase — tools built by
agents, adapted per project, shareable everywhere."

## Creation
Happens **inside the project window** (studio window retires): a
workspace-flavored flow — agent terminal + live preview tab + rail
presence in the existing Applets section — because adaptation needs
project context. Writes to `apps/` (or the library), never a worktree.
Confusion with runs is handled by chrome (app-window icon, Applet
badge/tint, own section), not by a separate window.

## Adaptation: declarative first, agent fallback
Manifest grows `needs:` — typed PRIMITIVE slots only:
- `repo` (path of a linked repo)
- `port` (a runner's port from run.toml / RunnerManager)
- `url`
- `connection` (Keychain-backed, extends Connections' applet-declared recipes)

Adopting binds slots from what the project already knows and writes
`bindings.json`, which the applet reads by scaffold convention. Zero
slots = instant install. Anything a primitive slot can't express is
"Adapt with Claude" — a short agent run in the standard agent-tab
machinery. Schema creep is the failure mode: `needs:` never grows
past primitives.

## Library
The global Applet Studio window dies; the library becomes data —
publish/adopt surfaced via the Library page and palette.

## Consequences
- Retire `app-studio` WindowGroup + AppStudioIntents routing; "New
  applet" (⌘L, ⇧⌘L, palette) lands in the in-project creation flow.
- Scaffold gains the bindings-read convention + `needs:` examples.
- e2e: createApplet/openApplet/adoptApplet re-route; PROTOCOL.md in
  lockstep; new bind/adapt commands for coverage.
- Adopt UI: binding form when slots exist; "Adapt with Claude" button
  always available.

## Open (for the plan, not blocking)
Migration of existing global-library applets; marketplace/sharing
beyond the local library.
