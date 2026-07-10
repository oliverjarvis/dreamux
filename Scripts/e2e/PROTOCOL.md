# Dreamux e2e automation protocol

Dreamux ships an in-app automation server for end-to-end testing. It
is compiled into every build but is **completely inert** unless the
`DREAMUX_E2E_SOCKET` environment variable is set at launch. It uses
**zero system permissions** — no Accessibility, no Screen Recording —
because every command runs inside the app process against its own
stores, and screenshots are rendered in-process via AppKit's
`cacheDisplay`.

Implementation lives in `Sources/Dreamux/E2E/` (`E2EServer.swift`
for the socket, `E2ECommands.swift` for command semantics,
`E2ERegistry.swift` for the store registry + UI bridge). Keep this
document in lockstep with `E2ECommands.swift`.

## Environment contract

Set these on the app process (e.g. when launching `Dreamux.app`'s
executable directly, or via `open --env`):

| Variable | Effect |
| --- | --- |
| `DREAMUX_E2E_SOCKET` | **The master switch.** Absolute path for the Unix domain socket the server binds. When set: the server starts before any window appears, and the launch-time notification-permission prompt is skipped (no dialogs mid-run). When unset, no e2e code runs at all. Keep the path short (Darwin caps `sun_path` at ~103 bytes — use `/tmp/...`, not a deep `$TMPDIR`). A stale socket file at this path is unlinked at startup. |
| `DREAMUX_E2E_AUTOOPEN` | Folder name of a project to open a window for right after launch. The launch gate looks the name up in the projects root and opens that project's window directly, so drivers don't have to script project selection. Must match the project's directory name exactly. |
| `DREAMUX_PROJECTS_ROOT` | Replaces `~/Documents/Dreamux` as the directory projects are discovered in / created under. Created on demand. Point it at a per-run sandbox so the user's real projects are never touched. |
| `DREAMUX_STATE_DIR` | Replaces `~/Library/Application Support/Dreamux` as the home of `projects.json`. Point it at a per-run sandbox. |
| `DREAMUX_APPS_ROOT` | Replaces `~/Documents/Dreamux/Apps` as the global App Studio applet library root (`AppLibraryStore`'s backing folder — see `adoptApplet`/`appletsState`). Point it at a per-run sandbox so `adoptApplet`/publish scenarios never touch the user's real library. Created on demand. |
| `DREAMUX_CLAUDE_BIN` | Absolute path to the `claude` binary the Run pane's Detect / Isolate / Diagnose buttons paste into their embedded terminal (it is shell-quoted for you). Point it at `Tests/Fixtures/bin/claude` for deterministic agent behavior regardless of the user's PATH/zshrc. When unset, the bare word `claude` is used. |
| `DREAMUX_GH_BIN` | Absolute path to the `gh` binary used by the merge sheet's "Create PR" path (`publishFeature`, `featurePRStatus`, and the sheet's own PR pre-check/polling). Point it at `Tests/Fixtures/bin/gh` — a fake that works against a **local bare repo as origin**, storing PR records inside the remote under `fake-prs/<branch>.json` and deriving MERGED from ref ancestry — so PR scenarios run with no network and no GitHub account. When unset, `gh` from PATH is used. |

A typical harness launch:

```sh
DREAMUX_E2E_SOCKET=/tmp/dreamux-e2e.sock \
DREAMUX_E2E_AUTOOPEN=demo \
DREAMUX_PROJECTS_ROOT=/tmp/dreamux-e2e/projects \
DREAMUX_STATE_DIR=/tmp/dreamux-e2e/state \
DREAMUX_APPS_ROOT=/tmp/dreamux-e2e/apps-root \
DREAMUX_CLAUDE_BIN="$REPO/Tests/Fixtures/bin/claude" \
DREAMUX_GH_BIN="$REPO/Tests/Fixtures/bin/gh" \
  ./Dreamux.app/Contents/MacOS/Dreamux
```

The socket is bound very early (in the SwiftUI `App` initializer), but
the driver should still retry-connect for a couple of seconds after
spawning the process before declaring failure.

## Wire format

- Unix domain stream socket at `$DREAMUX_E2E_SOCKET`.
- **Newline-delimited JSON**, one command per line: the client writes
  a single-line JSON object terminated by `\n`, the server writes back
  a single-line JSON object terminated by `\n`. No length prefixes, no
  pipelining guarantees beyond strict request/response ordering.
- Requests are objects with a required `"cmd"` string plus
  command-specific parameters at the top level.
- Every response contains `"ok": true` or `"ok": false`. Failures
  carry `"error": "<human-readable message>"`. Unknown commands fail
  with `ok:false`.
- A connection can carry many commands; the server handles one
  connection at a time, so use a single connection per driver (or
  connect-per-command — both work).
- Commands block until done: the server hops to the main actor per
  command and awaits completion (including `git` subprocesses for
  `mergeFeature` etc.) before replying. There is no server-side
  timeout; the driver should apply its own.

Python one-liner smoke test:

```python
import socket, json
s = socket.socket(socket.AF_UNIX); s.connect("/tmp/dreamux-e2e.sock")
s.sendall(json.dumps({"cmd": "ping"}).encode() + b"\n")
print(s.makefile().readline())   # -> {"ok":true}
```

## Targeting model

Commands that touch project state operate on **the currently shown
project** (each project registers when its window content appears and
unregisters when it disappears — so after a `switchProject` the target
follows the visible project). The underlying per-project state
(terminals, runners, the plan queue) survives switches either way;
only the harness's *target* moves. Single-window, single-project runs
— the normal e2e shape, via `DREAMUX_E2E_AUTOOPEN` — never notice.
Commands fail with
`ok:false` and a descriptive `error` when no project window has been
registered yet, so the driver can poll `state` (or just `ping` +
retry) until the auto-opened window is up.

Workspace ("feature"/"work item") parameters are matched **by name**
(the branch name), repos by their folder name under `repos/`.

## Commands

### `ping`

Liveness probe. Works before any window exists.

```
→ {"cmd":"ping"}
← {"ok":true}
```

### `state`

Snapshot of everything a scenario typically asserts on.

```
→ {"cmd":"state"}
← {
    "ok": true,
    "projects": [
      {"id":"4B5C…","name":"demo","path":"/tmp/dreamux-e2e/projects/demo"}
    ],
    "activeProject": {"id":"4B5C…","name":"demo","path":"…/demo"},
    "workspaces": [
      {"name":"feature-x","linkedRepoIDs":["webapp"],"isActive":true,
       "webTabs":["http://localhost:4600/"],
       "tabs":[{"title":"Overview","isOverview":true},
               {"title":"shell","isOverview":false}]}
    ],
    "runners": [
      {
        "name": "fixedport-server",
        "cwd": "repos/fixedport-server/main",
        "start": "python3 server.py",
        "port": 4700,
        "portEnv": "FIXEDPORT_SERVER_PORT",
        "instances": [
          {"branch":"main","status":"running","pid":4242,"assignedPort":4700}
        ]
      }
    ],
    "runTomlExists": true,
    "runToml": "[[runners]]\nname = …",
    "sidebarMode": "workspace",
    "openedTargets": ["http://localhost:4600/"],
    "plans": [
      {"path":"docs/plans/2026-07-02-x.md","status":"ready",
       "checkedSteps":0,"totalSteps":4}
    ],
    "initiatives": [
      {"title":"Game Boy Emulator","id":"gameboy",
       "specPath":"docs/specs/2026-07-02-gameboy-design.md",
       "docPaths":["docs/2026-07-02-gameboy-roadmap.md"],
       "plans":[
         {"path":"docs/plans/2026-07-02-gameboy-phase-1.md","status":"merged",
          "ordinal":1,"tasks":[{"title":"Task 1: CPU","checked":6,"total":6}]},
         {"path":"docs/plans/2026-07-02-gameboy-phase-2.md","status":"running",
          "ordinal":2,"tasks":[{"title":"Task 1: PPU","checked":1,"total":5}]}
       ]}
    ]
  }
```

Field notes:

- `projects` lists every project the `ProjectStore` discovered under
  the projects root; `activeProject` is the targeted window's project,
  or JSON `null` when no project window is registered.
- `workspaces[].isActive` — the workspace currently selected in the
  sidebar.
- `workspaces[].tabs` — the workspace's Bonsplit tab bar, in tab-bar
  order: `{"title", "isOverview"}` per tab. Every workspace bootstraps
  with its pinned, non-dismissable **Overview** tab created first
  (`title: "Overview"`, `isOverview: true`) — this is how a scenario
  confirms it exists and sits leftmost without a screenshot. Bootstrap
  runs off a SwiftUI `onAppear` the moment the workspace's pane mounts
  (which needs `sidebarMode` to be `"workspace"`), so a workspace
  created moments ago may briefly report `tabs: []`; poll `state`
  rather than assuming it's already there.
- `runners` mirrors the parsed `run.toml`. `cwd`, `port`, `portEnv`
  are **omitted** when absent. `instances` holds one entry per
  (runner, branch) the manager has ever started this session:
  `status` is `"idle" | "running" | "exited" | "failed"`, with `pid`
  (running), `exitCode` (exited), `error` (failed), and
  `assignedPort` (port-env-isolated instances while live) present
  only when applicable.
- `runToml` is omitted when the file doesn't exist
  (`runTomlExists: false`).
- `sidebarMode` is `"workspace" | "run" | "signals" | "flows" | "library" | "app"`
  — the pane the project window currently shows.
- `openedTargets` — every `open` target the runner manager fired this
  session, in order (a runner's `open` value with `{port}` resolved to
  the instance's effective port). URL targets open as in-app browser
  tabs in the branch's workspace (reported per-workspace via
  `workspaces[].webTabs`); in e2e mode the EXTERNAL fallbacks
  (browser/shell command) are suppressed, while in-app tabs stay
  enabled and observable.
- `plans` mirrors `DocStore.plans` (docs classified as plans only,
  i.e. not specs/plain docs): `status` is the same derived value
  `listDocs` reports (ledger + checkboxes + feature existence). Each
  entry also carries its ordering disposition: `runsAfter` (the blocker
  plan's project-relative path, from a `**Runs:** after <plan>` header)
  and `declaresParallel: true` (from a `**Runs:** parallel` header).
  Both follow `specPath`'s omitted-not-null convention — `runsAfter` is
  **omitted** when the plan names no blocker, `declaresParallel`
  **omitted** when the plan doesn't explicitly opt into parallel — and
  are mutually exclusive on a well-formed header. A plan with a parked
  live nudge (a course correction or intake-integrate re-read waiting on
  the agent's quiescence) also carries `pendingNudges` — the count of
  nudges parked for it (0 or 1; at most one parks per plan). It follows
  the same omitted-not-null convention: **omitted** (never `0`) when no
  nudge is parked. See `courseCorrect`.
- `initiatives` mirrors `DocStore.initiatives` — the same work grouped
  into families (spec + ordered plans + supporting docs) the sidebar
  renders. Entries come in **store order** (newest member date first),
  NOT the sidebar's render order (active-first by status rank, merged
  work folded into Done) — match entries by `id`, never by index. Each
  entry: `title`, `id` (family key), `specPath` (**omitted** when the
  initiative has no spec), `docPaths` (supporting docs — roadmaps,
  extra specs), and `plans`, each with its 1-based `ordinal`
  (execution order), derived `status` (as in `plans`), the same
  `runsAfter` / `declaresParallel` disposition and `pendingNudges` fields
  the flat `plans` entries carry (each omitted when not declared / no
  nudge parked), and a per-`tasks` checkbox rollup (`title`, `checked`,
  `total`). `tasks` reports every
  parsed heading — a heading with no checkboxes dumps as `total: 0` even
  though the sidebar hides such rows, and its `title` may be empty for
  steps that precede the first heading. Each task also carries `phase`,
  the `## ` section it falls under in single-file phased plans (omitted
  when the plan has no sections). All paths are project-relative. The
  flat `plans` array above stays for compatibility.
- **Enactment.** Dropping a plan whose header reads `**Runs:** after
  <blocker>` into the docs home self-enqueues it behind its blocker on
  the next watcher tick — the plan appears in `queue.entries` after its
  blocker with no explicit `enqueuePlan`, observable via `queueState`.
  Enactment is edge-triggered: it fires once when the waiter first
  appears, so a waiter a driver manually removes from the queue stays
  removed rather than being re-enqueued on the next tick.
- `queue` mirrors `PlanQueueController`: `{"state":
  "idle|running|atGate|attention", "entries": ["docs/plans/…"],
  "current": "docs/plans/…"?}`. `current` is omitted while the queue
  is idle; JSON `null` when no plan queue is registered. Unlike
  `queueState`, reading `state` does **not** tick the queue — poll
  `queueState` to force a transition.
- Empty-but-registered states return empty arrays, never `null`.

### `screenshot`

Render the project window into a PNG at an **absolute** path
(directories must already exist). The window is brought to front
first (`NSApp.activate` + `makeKeyAndOrderFront`). When a sheet is
attached (e.g. after `openMergeSheet`), the sheet is captured instead
of the window behind it. Rendering uses
`bitmapImageRepForCachingDisplay`/`cacheDisplay` — no Screen Recording
permission. **Caveat:** GPU-backed surfaces (the embedded Ghostty
terminals) may render blank/black, and vibrancy/material backgrounds
(sheets, sidebars) can come out washed out; screenshots document the
UI chrome and its state (badges, rows, buttons), not pixel-perfect
window compositing or terminal contents.

```
→ {"cmd":"screenshot","path":"/tmp/dreamux-e2e/shots/01-sidebar.png"}
← {"ok":true,"path":"/tmp/dreamux-e2e/shots/01-sidebar.png","width":2456,"height":1234}
```

### `addLocalRepo`

Import an existing local git repository into the project —
`RepoStore.importLocal`, i.e. `git clone --bare <path>` into
`repos/<name>/.bare` plus a default-branch worktree. The source folder
is untouched.

```
→ {"cmd":"addLocalRepo","path":"/tmp/seed/webapp","name":"webapp"}
← {"ok":true,"name":"webapp","defaultBranch":"main","path":"…/demo/repos/webapp"}
```

### `createFeature`

Create a work item spanning one or more repos — the same code path as
the sidebar's Add Feature sheet (`FeatureProvisioner.provision`: one
worktree per repo on a branch named after the feature, plus the
`features/<name>/` symlink aggregation dir, then
`WorkspaceStore.registerFeature`). Fails (with the provisioner's
error message) if the feature already exists, a repo is unknown, etc.
The sidebar has no Features list anymore: a plan-less workspace created
this way appears under the sidebar's **Ad hoc** group (whose header now
hosts the Add Feature `+`), while plan-backed workspaces are reachable
from their Plans & Specs rows. Either way the `state` `workspaces` dump
is store-level and unchanged.

```
→ {"cmd":"createFeature","name":"feature-x","repos":["webapp"]}
← {"ok":true,"featureDirectory":"…/demo/features/feature-x"}
```

### `openMainWorkspace`

Materialize (find-or-create) and activate the reserved **main**
workspace — the same `WorkspaceStore.mainWorkspace` find-or-create plus
activation the sidebar's permanent main row runs on click
(`WorkspaceSidebar.openMainWorkspace()`). The sidebar has no other
button a driver can press for it, so this is the only e2e path to the
main workspace's Overview (Mode B's project mini-dashboard, Task 7).
`name` is the first linked repo's default branch (`"main"` if there are
none), matching what the row itself derives. Also switches
`sidebarMode` to `"workspace"` (needed for the workspace's Bonsplit
pane to mount and bootstrap its Overview tab — see `state`'s
`workspaces[].tabs`).

```
→ {"cmd":"openMainWorkspace"}
← {"ok":true,"name":"main"}
```

### `setSidebarMode`

Switch the project window's main pane. `mode` is `"workspace"`,
`"run"`, `"signals"`, `"flows"`, `"library"`, or `"app"` — `flows` shows
the Flows observatory (see `flowsState`), `library` the Skills & MCPs
inventory page, and `app` an open App Studio applet (requires a UUID
`"id"` parameter — the applet's manifest id, as returned by
`createApplet`/`openApplet`/`adoptApplet`; prefer `openApplet` with a
`slug`, which resolves the id for you). The optional `"workspace"`
parameter (a feature name) selects which workspace to activate (for
`workspace` mode) or to scope the Run pane to (for `run` mode; defaults
to the active workspace, then the first one — fails if there are
none). `flows`, `library`, and `app` ignore `workspace` — none of the
three are per-workspace.

```
→ {"cmd":"setSidebarMode","mode":"run","workspace":"feature-x"}
← {"ok":true}

→ {"cmd":"setSidebarMode","mode":"flows"}
← {"ok":true}

→ {"cmd":"setSidebarMode","mode":"app","id":"3FA85F64-5717-4562-B3FC-2C963F66AFA6"}
← {"ok":true}
```

### `switchProject`

Flip the project window to another project by name — the same binding
write clicking it in the rail performs. Per-project state (terminals,
runners, the plan queue) survives the switch; only the view layer is
rebuilt. The switch settles asynchronously: poll `state` until
`activeProject.name` matches before issuing project-scoped commands.

```
→ {"cmd":"switchProject","project":"proj-b"}
← {"ok":true,"projectID":"<uuid>"}
```

### `terminalText`

Visible-viewport text of every terminal tab in a workspace, read
straight from libghostty (`texts`, one string per tab, lines joined
with `\n`). This is the probe for terminal *contents* — the in-process
`screenshot` renders GPU-composited surfaces blank. `feature` is
optional and defaults to the active workspace. Tabs whose surface
hasn't attached yet are omitted from `texts`.

```
→ {"cmd":"terminalText","feature":"feature-x"}
← {"ok":true,"feature":"feature-x","texts":["% echo hi\nhi\n%"]}
```

### `sendTerminalText`

Type into one of a workspace's terminal tabs as if the user did —
deterministic only for single-tab workspaces (tab order is not
defined; keep scenario workspaces to one shell tab, same as
`terminalText`'s `texts` order). `"submit":true` appends a carriage
return so the shell executes it.
Fails with `ok:false` until the shell has been quiescent for ~0.8 s (a
booting zsh flushes its input queue and would silently eat the send) —
retry on error. `feature` is optional and defaults to the active
workspace.

```
→ {"cmd":"sendTerminalText","feature":"feature-x","text":"echo hi","submit":true}
← {"ok":true,"feature":"feature-x"}
```

### `startFeature`

Press Play on a workspace, via `RunnerManager.startPlan`. Play is
worktree-centric and never blocks on a question: runners with
flexible ports (port_env, or no port) start alongside other
worktrees' instances; fixed-port runners **switch** — their live
instance on another worktree is stopped as part of starting, and
`displaced` reports each such switch (the sidebar renders the same
information as a transient notice with an isolate shortcut).

```
→ {"cmd":"startFeature","name":"feature-x"}

# started; nothing else was running on a fixed port
← {"ok":true,"started":true,"runners":["fixedport-server"],"displaced":[]}

# started by switching: feature-y's instance was stopped first
← {"ok":true,"started":true,"runners":["fixedport-server"],
   "displaced":[{"runner":"fixedport-server","fromBranch":"feature-y"}]}

# no runners configured at all (the UI would open the Run pane)
← {"ok":true,"started":false,"reason":"no runners configured"}
```

Starting is asynchronous — poll `state` until the expected instances
show `"status":"running"` (and, after a switch, until the displaced
instance stops).

### `startFeatureReplacing`

Deprecated alias of `startFeature`, kept for protocol compatibility:
switching is now `startFeature`'s default behavior, so both commands
do the same thing.

```
→ {"cmd":"startFeatureReplacing","name":"feature-x"}
← {"ok":true,"started":true,"runners":["fixedport-server"],"displaced":[]}
```

### `stopFeature`

Stop every runner instance currently live on this workspace's
worktree (per-instance; the same runner stays alive on other
branches). `stopped` lists the runner names that had a live instance.
Stopping is asynchronous too (SIGTERM) — and a start/restart still in
flight from an earlier command can bring a fresh instance up
afterwards, exactly as in the UI. Poll `state` for the settled
picture.

```
→ {"cmd":"stopFeature","name":"feature-x"}
← {"ok":true,"stopped":["fixedport-server"]}
```

### `isolateRunner`

The conflict alert's **Isolate with Claude** path: parks the named
runner on `RunnerManager.pendingIsolation` and switches the sidebar to
Run mode (scoped to the workspace matching the runner's current
branch when one exists). The Run pane consumes the pending isolation
on appearance and sends the isolate prompt to the `claude` CLI
(`DREAMUX_CLAUDE_BIN`) in its embedded terminal. The reply does
**not** wait for the agent — poll the repo/`run.toml` on disk (or
`reloadRunConfig` + `state`) for the isolation to land.

```
→ {"cmd":"isolateRunner","name":"fixedport-server"}
← {"ok":true}
```

### `detectRunConfig`

Click the Run pane's **Detect Run Config** button: switches the
sidebar to Run mode and has the pane send the detect prompt to the
`claude` CLI in its embedded terminal. Like `isolateRunner`, the reply
does not wait for the agent — poll for `.dreamux/run.toml`, then
call `reloadRunConfig`.

```
→ {"cmd":"detectRunConfig"}
← {"ok":true}
```

### `reloadRunConfig`

Re-read `<project>/.dreamux/run.toml` from disk and re-parse the
runner list (the Run pane's refresh button).

```
→ {"cmd":"reloadRunConfig"}
← {"ok":true,"runTomlExists":true,"runners":["fixedport-server","portenv-server"]}
```

### `mergeFeature`

Drives the merge sheet's own orchestration (`MergeFlow` — the exact
code the sheet runs) for **one repo**, headless: the sheet's on-appear
pre-check, then its "Commit & Merge" path when the feature worktree
has uncommitted changes (`git add -A && git commit` with the workspace
name as the message) or its plain Merge otherwise (`git merge --no-ff`
into the default-branch worktree; skipped when zero commits are ahead).
A conflicted merge is left in place for resolution (use
`screenshot`/`openMergeSheet` to document it, or resolve out-of-band),
exactly like the sheet.

```
→ {"cmd":"mergeFeature","name":"feature-x","repo":"webapp"}
← {"ok":true,"outcome":"merged","paths":[]}
← {"ok":true,"outcome":"alreadyUpToDate","paths":[]}
← {"ok":true,"outcome":"conflicted","paths":["server.py"]}
```

### `publishFeature`

Drives the merge sheet's **Create PR** path (`MergeFlow.publish`, or
`commitAndPublish` when the feature worktree has uncommitted changes)
for **one repo**, headless: the sheet's on-appear pre-check first,
then `git push --set-upstream origin <branch>` and `gh pr create`
against the repo's default branch. The local default branch is
untouched — integration happens on the remote. Because the pre-check
resumes an existing PR's state from gh, re-running the command reports
the PR that already exists (`prOpen`/`prMerged`) instead of failing —
as idempotent as re-clicking the button after a sheet re-open.

Fails on the same verdicts that hide/disable the sheet's button: the
repo has no `origin` remote, or no `gh` CLI is reachable (point
`DREAMUX_GH_BIN` at `Tests/Fixtures/bin/gh`). Also fails when there
is nothing to publish (zero commits ahead of base), when the worktree
is missing, or when the push/PR creation itself errors.

```
→ {"cmd":"publishFeature","name":"feat-pr","repo":"pr-server"}
← {"ok":true,"state":"prOpen","url":"https://fake-gh.example/portenv-server/pull/1"}
← {"ok":false,"error":"nothing to publish: \"feat-pr\" has no commits ahead of main"}
← {"ok":false,"error":"repo \"local-only\" has no origin remote to push to"}
```

### `featurePRStatus`

Where the feature's PR stands for **one repo**, via a fresh
`MergeFlow` + the sheet's on-appear pre-check (`initializeStates`,
which resumes PR state from gh). Every call re-asks gh, so this is how
a driver observes a remote-side PR merge promptly instead of waiting
out the throttled (~10s) PR poll an open sheet would be running.
`state` is the pre-check's verdict: `"prOpen"` / `"prMerged"` (each
with `"url"`), or any other pre-check state when no PR exists —
`"pending"` (commits ahead, nothing published), `"upToDate"`,
`"featureDirty"`, `"cleanedUp"` (worktree gone). `url` is omitted
unless the state refers to a PR.

```
→ {"cmd":"featurePRStatus","name":"feat-pr","repo":"pr-server"}
← {"ok":true,"state":"prOpen","url":"https://fake-gh.example/portenv-server/pull/1"}
← {"ok":true,"state":"prMerged","url":"https://fake-gh.example/portenv-server/pull/1"}
← {"ok":true,"state":"pending"}
```

### `openMergeSheet`

Open the real merge sheet for a workspace (for screenshots of the
actual UI). Activates the workspace, then the sidebar presents the
sheet. Note: while a previously opened sheet is still attached,
re-issuing this command for the same workspace is a no-op (the sheet —
and its `MergeFlow` — keeps its presentation); relaunch the app to get
a sheet whose pre-check runs fresh, as the publish-pr scenario does.

```
→ {"cmd":"openMergeSheet","name":"feature-x"}
← {"ok":true}
```

### `cleanupFeature`

Drives the merge sheet's own per-repo cleanup (`MergeFlow.cleanup`,
"Cleanup Worktree & Branch" on every row) across every linked repo,
with the callbacks wired the way the sidebar wires them: each repo's
`git worktree remove` + `git branch -D` + symlink removal is followed
by stopping runners executing on that worktree and clearing their
branch overrides; after the last repo, the workspace is dropped from
the sidebar and the `features/<name>/` aggregation directory deleted.

Like the sheet, the flow's pre-check runs first, so a repo whose PR
merged on the remote resumes `prMerged` and cleanup **fast-forwards
local main from origin** (`git fetch` + `git merge --ff-only`) before
the worktree and branch are removed — local main ends up containing
the remotely merged work, same as after a local merge.

```
→ {"cmd":"cleanupFeature","name":"feature-x"}
← {"ok":true}
```

### `openFile`
Open a file as a Monaco editor tab in the active (or named) workspace.
Request: `{"cmd":"openFile","path":"/abs/path/to/file","workspace":"<name?>"}`
Response: `{"ok":true}`

### `setFileTree`
Show/hide the right-side file explorer inspector.
Request: `{"cmd":"setFileTree","visible":true}`
Response: `{"ok":true}`

`state`'s `workspaces[].fileTabs` reports open editor tabs, one object per tab:
`{"path": "<resolved absolute path>", "kind": "code|markdown|image|video|audio|pdf|officePreview|tabular", "mode": "rendered|source|table", "dirty": "true|false"}`.
`kind` is decided from the file extension at open; `mode` is the
active face of multi-mode viewers (markdown rendered/raw, tabular
table/text).

### `listDocs`

Rescan the project docs home (`<project>/docs/`) and return every
markdown doc: `{"ok": true, "docs": [{"path", "kind": "plan|spec|doc",
"title", "status": "specOnly|ready|inProgress|running|awaitingReview|merged",
"checkedSteps", "totalSteps", "spec"?}]}`. `status` is derived (ledger +
checkboxes + feature existence); only plans have meaningful statuses.

```
→ {"cmd":"listDocs"}
← {"ok":true,"docs":[
    {"path":"docs/plans/2026-07-02-x.md","kind":"plan","title":"X",
     "status":"ready","checkedSteps":0,"totalSteps":4,
     "spec":"docs/specs/2026-07-02-x-design.md"}
  ]}
```

### `runPlan`

`{"cmd": "runPlan", "path": "docs/plans/2026-07-02-x.md", "branch"?:
"x", "repos"?: ["api"]}` — executes the plan through the same
coordinator as the sidebar: provisions the feature worktrees (branch
defaults to the filename minus its date prefix; repos default to all),
records the run ledger entry, opens a `plan: <branch>` terminal tab,
and types the claude invocation (`DREAMUX_CLAUDE_BIN` substitutes the
fake). Replies `{"ok": true, "feature": "<branch>"}`.

```
→ {"cmd":"runPlan","path":"docs/plans/2026-07-02-x.md"}
← {"ok":true,"feature":"x"}
```

### `enqueuePlan`

Append a plan path to the queue (`PlanQueueController.enqueue`) — a
no-op if it's already queued. Does not start the queue.

```
→ {"cmd":"enqueuePlan","path":"docs/plans/2026-07-02-x.md"}
← {"ok":true}
```

### `startQueue`

Start the queue (`PlanQueueController.start`): if idle with at least
one entry, launches the first plan via `runPlan` and moves to
`"running"`. A no-op when already running or empty.

```
→ {"cmd":"startQueue"}
← {"ok":true}
```

### `stopQueue`

Stop the queue (`PlanQueueController.stopQueue`): resets to `"idle"`,
clears the current plan, and cancels the poller. Does not touch
anything the current plan already started (worktrees, terminals).

```
→ {"cmd":"stopQueue"}
← {"ok":true}
```

### `skipQueueGate`

Drop the current queued plan (`PlanQueueController.skipCurrent()`,
e.g. one a prior scenario left parked `atGate`) and advance
immediately — no merge, no git dependency. The real UI has no button
for this (a stuck gate is meant to be resolved via the merge sheet,
not abandoned); it exists purely as a test-only escape hatch so a
scenario can free the single-lane queue of a leftover plan another
scenario left blocking it, without reimplementing that scenario's own
merge/cleanup.

```
→ {"cmd":"skipQueueGate"}
← {"ok":true}
```

### `dequeuePlan`

Remove a plan from the queue's `entries` outright
(`PlanQueueController.remove(path)`), clearing `currentPlanPath` too if it
matched. Unlike `skipQueueGate`, this needs no `current` and launches
nothing — the deterministic way to drain a plan a prior scenario left
parked in `entries` after its `stopQueue` (which nulls `current` but keeps
`entries`). Test-only; the real UI removes queued rows via the row's ✕.

```
→ {"cmd":"dequeuePlan","path":"docs/plans/2026-07-06-gate-demo.md"}
← {"ok":true}
```

### `queueState`

Snapshot of the plan queue, after running one synchronous
`PlanQueueController.tick()` — the same transition logic the 3s
background poller drives, but forced immediately so scenarios don't
race a timer. This is how a driver deterministically walks the state
machine: tick a plan's checkboxes to done, call `queueState`, and
assert `"atGate"` shows up on that call rather than an arbitrary one a
few seconds later.

`{"ok": true, "state": "idle|running|atGate|attention", "entries":
["docs/plans/…"], "current"?, "lastError"?}` — `current` is present
whenever a plan is active (`running`/`atGate`/`attention`);
`lastError` only after a launch or disappearance failure. `entries`
keeps the current plan until it merges or is skipped — it isn't
removed just because the plan reached the gate — so `entries` and
`current` overlap for the active plan; only after a merge/skip
advances the queue past it does it drop out of `entries`.

```
→ {"cmd":"queueState"}
← {"ok":true,"state":"atGate","entries":["docs/plans/2026-07-02-x.md"],
   "current":"docs/plans/2026-07-02-x.md"}
```

### `flowsState`

Snapshot of the Flows pane's session lanes (`FlowStore`) — live claude
sessions and their subagents/tasks, fed by the `<claude-home>/sessions/`
registry (3s poll) and hook signals delivered over the emit socket
(`SignalEmitSocketServer`, `agent.started`/`agent.stopped`/
`task.created`/`task.completed`/`session.stopped`/
`session.notification`) — plus `planLanes`, one per non-`specOnly` plan,
built by the same `PlanLaneAssembler` + `PlanFlowBuilder` the Flows pane
itself calls, so this can't drift from what's on screen (`planLanes` is
`[]` if the Docs section or plan queue haven't come on screen yet in
this window).

```
→ {"cmd":"flowsState"}
← {"ok":true,"running":1,"needsYou":0,"boardRunning":1,"boardNeedsYou":0,
   "lanes":[
     {"id":"session-e2e-session-1","title":"flows-demo","kind":"adhoc",
      "status":"running",
      "nodes":[
        {"id":"src","label":"prompt","status":"done"},
        {"id":"session","label":"claude","status":"running"},
        {"id":"agent-e2e-a1","label":"Explore","status":"running"},
        {"id":"drain","label":"done","status":"queued"}
      ],
      "edges":[
        {"from":"src","to":"session","kind":"sequence"},
        {"from":"session","to":"agent-e2e-a1","kind":"spawn"},
        {"from":"session","to":"drain","kind":"sequence"},
        {"from":"session","to":"session","kind":"loop","label":"Bash:swift","iterations":3}
      ]}
   ],
   "planLanes":[
     {"id":"plan-docs/plans/2026-07-02-x.md","title":"X Implementation Plan",
      "kind":"plan","status":"running",
      "nodes":[
        {"id":"src","label":"plan","status":"done"},
        {"id":"phase-0","label":"tasks","status":"running"},
        {"id":"drain","label":"merge","status":"queued"}
      ],
      "edges":[
        {"from":"src","to":"phase-0","kind":"sequence"},
        {"from":"phase-0","to":"drain","kind":"sequence"}
      ]}
   ]}
```

Field notes:

- `lanes[].id` is `"session-<sessionId>"` (from the registry entry or
  the hook signal's `session_id`). `kind` is `"adhoc"` (interactive),
  `"scheduled"` (registry `kind: "bg"`), or `"plan"` (never emitted
  here). `status` is derived from the lane's nodes —
  `waiting` beats `running` beats `failed` beats `queued`, else `done`
  — so a lane reads "needs you" the instant any node is waiting.
- `nodes[].id` follows the source: `"src"`/`"session"`/`"drain"` are the
  fixed skeleton every session lane starts with; hook-derived nodes are
  `"agent-<agent_id>"` or `"task-<task_id>"`.
- `lane.detail` (omitted unless set) carries the last
  `session.notification` message; it's cleared whenever the lane
  leaves the waiting state.
- `lane.detailUnavailable` (omitted unless `true`) is set once a
  session's transcript tail has dropped 50+ unparsable lines, so its
  activity detail can no longer be trusted; it never clears back to
  false.
- `running`/`needsYou` are `FlowStore`'s raw session-lane aggregates —
  counts of lanes whose derived `status` is `running` / `waiting`,
  respectively — session lanes only, before any plan-lane merge.
- `boardRunning`/`boardNeedsYou` are the composed `FlowsBoard`'s counts:
  plan lanes plus session lanes, after a suppressed ad hoc session's
  status bubbles onto its plan lane and after counting `waiting` **or**
  `failed` as needs-you. These are what the pane header badge and the
  sidebar tile badge both show — the two used to diverge (a plan
  sitting at its gate with no live session lit the pane but left the
  tile dark); they're unified as of this field, so read `boardRunning`/
  `boardNeedsYou` for "does anything need attention", not `running`/
  `needsYou`.
- A lane only appears here if its cwd (registry entry `cwd`, or the
  hook signal's `tags.cwd`) resolves to a real workspace — the feature
  aggregation dir or a per-repo worktree path (`FlowWiring.workspaceID`)
  — or the project root itself; otherwise the app's `isInProject`
  scoping drops it silently.
- `planLanes[].id` is `"plan-<planPath>"` (project-relative path, same
  string `listDocs`/`state` report). `nodes[].id` follows
  `PlanFlowBuilder`'s fixed skeleton: `"src"`, `"phase-<n>"` (one per
  summarized phase or task group), an optional `"gate"` when the plan
  needs review/merge or the queue is `atGate`/`attention` on it, then
  `"drain"`. `lane.detail` (omitted unless set) carries `"queued
  #<n>"` while the plan sits in the queue unstarted.
- `nodes[]`'s sibling `edges[]` array (both session and plan lanes)
  mirrors `Flow.edges`: `{"from", "to", "kind"}` plus `label`/
  `iterations`, each **omitted** unless the edge carries it. `kind` is
  one of `"sequence" | "spawn" | "dependency" | "message" | "loop"`. A
  lane carries at most one `"loop"` edge, always self-referential
  (`from == to == "session"`) — its `label` is the repeating tool
  signature (e.g. `"Bash:swift"`) and `iterations` the repeat count;
  it disappears once the repetition breaks or the session ends.
- `lane.sessionCwd` (omitted unless known) is the backing session's
  working directory — populated once the registry has observed the
  session at least once. `nodes[].lastActivity` (omitted unless set) is
  a one-line summary of that node's most recent transcript activity
  (tool call summary for the session node, subagent meta description
  for an agent node) — the same text the zoom detail view's inspector
  shows.

### `zoomFlow`

Zoom the Flows pane into one lane's DAG detail view (`FlowDetailView`),
or clear the zoom back to the overview. `laneID` is a `flowsState`
lane id (`"session-<sessionId>"` or `"plan-<planPath>"`); omit it or
pass `null` to clear. Parked on the bridge and adopted by `ContentView`
the same consume-and-clear way `setSidebarMode` is — call `flowsState`
afterward (or just wait) to confirm the zoom landed before screenshotting,
since adoption happens on the next SwiftUI update pass. Zooming into a
lane with a `sessionID` triggers a one-time full replay of that
session's transcript (`ProjectSession.beginFlowsZoom`, the pool's
`ensureLazyTail`) — the hot-tail path (used while a session is merely
`running`/`waiting`) only ever reads from the point it started
watching, so a transcript written to disk before the session first
entered the hot set is otherwise never read at all; zooming is the only
way to pull that history in.

Leaving the Flows pane (`setSidebarMode` to anything else) clears the
zoom — re-entering `flows` always lands back on the overview, never a
stale zoomed lane; re-zoom explicitly if needed.

```
→ {"cmd":"zoomFlow","laneID":"session-e2e-session-1"}
← {"ok":true}

→ {"cmd":"zoomFlow","laneID":null}
← {"ok":true}
```

### App Studio applets

Five commands cover the applet lifecycle a driver can reach without a
mouse: scaffold, open (mount the live `WKWebView` + native bridge),
adopt from the library, remove, and a state snapshot. All five operate
on **the active project's** applets (`ProjectSession.applets`); slugs
are matched exactly as returned by `createApplet`/`appletsState`.

**Caveat shared by every one of these:** the applet preview is a real
`WKWebView`, and WKWebView content is GPU-composited — it comes out
**blank** in the in-process `screenshot` (same limitation as the
embedded Ghostty terminals, see `screenshot` above). A `screenshot`
after `openApplet` documents the chrome around it (the APPS section
row, the host header/Edit/Reload/Reveal buttons) but proves nothing
about what's rendered inside the preview. To assert the bridge actually
worked, poll **disk state** instead: every `kv.*` call round-trips
through `AppletDataStore` to `<project>/.dreamux/appdata/<slug>/kv.json`,
so a scenario that has the applet's own JS write a marker value there
can confirm the whole chain (scheme handler served the page → JS ran →
bridge gated the capability → data store wrote) without ever looking at
a pixel.

#### `createApplet`

Scaffold a local-born applet (no `origin`) via
`ProjectAppletStore.createLocal` — the buildless HTML/JS template
(vendored Preact + htm, the `window.dreamux` bridge shim, `APPLET.md`)
under `<project>/apps/<slug>/`, slug uniqued from `name`. **No builder
agent is kicked off** — unlike the real "New App" sheet
(`WorkspaceSidebar.handleCreateApp`), this command never spawns
`claude`, since the agent isn't e2e-testable. Icon is always
`"shippingbox"`.

```
→ {"cmd":"createApplet","name":"Probe","description":"e2e probe"}
← {"ok":true,"slug":"probe","id":"3FA85F64-5717-4562-B3FC-2C963F66AFA6"}
```

#### `openApplet`

Mount an applet's host view (`AppletHostView` + its `WKWebView`) —
resolves `slug` against the project's live `ProjectAppletStore`
(refreshed first, so a manifest/index.html a driver just rewrote
directly on disk is picked up before the first load) and drives
`sidebarMode = .app(id)` through the same pending-mode channel
`setSidebarMode` uses. The FIRST call for a given applet id creates its
`AppletSession` (and therefore its `WKWebView`, loading `index.html` for
the first time) with whatever capabilities `manifest.json` declares at
that moment; later calls reuse the cached session — a manifest edited
after the first open takes effect via the session's own 1s hot-reload
poller (folder mtime), not by re-resolving here. Errors when `slug`
doesn't match any applet in the project.

```
→ {"cmd":"openApplet","slug":"probe"}
← {"ok":true,"id":"3FA85F64-5717-4562-B3FC-2C963F66AFA6"}

→ {"cmd":"openApplet","slug":"nope"}
← {"ok":false,"error":"no applet with slug \"nope\" in this project"}
```

#### `adoptApplet`

Copy a library applet into the project — `ProjectAppletStore.adopt`,
the same call `WorkspaceSidebar.handleAdoptApp` makes. Resolves `slug`
against a **fresh** `AppLibraryStore()` (honors `$DREAMUX_APPS_ROOT`)
rather than the session's cached one, so a library folder a driver just
wrote straight to disk (bypassing the app entirely) is picked up
immediately — `AppLibraryStore.init` always refreshes. Returns the new
project-side copy's slug + id (uniqued against the project, may differ
from the library applet's own slug on a collision).

```
→ {"cmd":"adoptApplet","slug":"lib-probe"}
← {"ok":true,"slug":"lib-probe","id":"7C1B2E10-...-...-...-..."}

→ {"cmd":"adoptApplet","slug":"nope"}
← {"ok":false,"error":"no library applet with slug \"nope\""}
```

#### `removeApplet`

Remove an applet from the project — mirrors
`WorkspaceSidebar.handleRemoveApp`: stops its live session first
(builder-agent terminal + hot-reload poller, via
`ProjectSession.closeAppletSession`) and only then deletes its folder
under `apps/` AND its `.dreamux/appdata/<slug>/` data dir
(`ProjectAppletStore.remove`) — not Trash, permanent, same as the real
remove action. Errors when `slug` doesn't match any applet in the
project.

```
→ {"cmd":"removeApplet","slug":"lib-probe"}
← {"ok":true}
```

#### `appletsState`

Snapshot of both applet lists, for asserting create/adopt/remove
without a screenshot: `projectApplets` (this project's `apps/` folder,
`adopted` is `true` iff the applet's manifest carries an `origin`) and
`libraryApplets` (the global library, read from a fresh
`AppLibraryStore()` for the same live-disk-state reason `adoptApplet`
uses one).

```
→ {"cmd":"appletsState"}
← {"ok":true,
   "projectApplets":[{"slug":"probe","name":"Probe","adopted":false}],
   "libraryApplets":[{"slug":"lib-probe","name":"Lib Probe"}]}
```

### Applet Connections

Three commands cover the pieces of the Connections feature an e2e driver
needs that aren't reachable through the applet bridge itself (a driver has
no way to click the Settings "Add Connection" button or the host view's
bind sheet). All three operate on the app-wide `ConnectionStore.shared`
and the active project's applets, exactly like the bridge's own
`connections.status`/`{connection}` handling reaches them — no parallel
test implementation.

**Launch requirement:** set `$DREAMUX_CONNECTIONS_SECRET_DIR` to a
per-run temp dir on the app process *before* it starts. `ConnectionStore
.shared` is a lazy singleton that decides file-backed
(`FileSecretStore`) vs. the real macOS Keychain on its **first** touch
anywhere in the process — as early as the first `AppletSession`'s
`init` — reading the env var once at that moment. Setting it after
launch, or launching without it and hoping to set it before the first
`createConnection`, does nothing; a token would land in the real
Keychain instead. (`Scripts/e2e/driver.py`'s `scenario_connections`
always launches — or relaunches, quitting an already-live process from
an earlier scenario first — its own app process with this set, for
exactly this reason.)

**Why there's no authenticated-fetch-to-localhost scenario:**
`AppletBridge`'s `http.fetch` runs through plain `URLSession.shared`
with no delegate, so a self-signed localhost TLS cert is rejected at
the TLS layer before any request lands, and the authenticator correctly
refuses to attach a token over plain `http`. Reaching a live
authenticated `200` would require test-only TLS-trust code in the app
itself, which isn't worth adding. `scenario_connections` instead proves
the same security-critical slot → binding → connection → token
composition **without any network round-trip**: an `env`-kind
connection's token really reaches a `shell.exec` call's process env
(asserted by having the shell echo its own injected env var back into
`kv.json`), and a `bearer`-kind connection's token is refused for a
host outside its own allowlist — rejected by `ConnectionAuthenticator`
*before* `URLSession` is ever called, so the negative case needs no
server listening at all; the assertion is that nothing was sent.

#### `createConnection`

Create a connection — `ConnectionStore.shared.add(...)`, the same call
the Settings management UI (add-manually) and the CLI importer both
make. `kind` is `"bearer"` (→ `AuthKind.header("Authorization", "Bearer
{token}")`, an HTTP kind — pairs with `http.fetch`) or `"env"` (→
`AuthKind.env(vars: [envVar])`, shell-only — pairs with `shell.exec`;
requires the `envVar` parameter). `hosts` is the connection's own
**enforced** allowlist (ignored for `"env"`, which has no HTTP surface).
The token is written through `SecretStoreFactory.makeDefault()` — see
the launch requirement above.

```
→ {"cmd":"createConnection","id":"github","kind":"bearer","token":"tok-123","hosts":["api.github.com"]}
← {"ok":true,"id":"github"}

→ {"cmd":"createConnection","id":"eas","kind":"env","envVar":"EAS_TOKEN","token":"tok-456","hosts":[]}
← {"ok":true,"id":"eas"}

→ {"cmd":"createConnection","id":"x","kind":"oauth","token":"t","hosts":[]}
← {"ok":false,"error":"unknown connection kind \"oauth\" (expected \"bearer\" or \"env\")"}
```

#### `bindConnection`

Bind a manifest-declared slot on one applet (matched by `slug`, in the
active project) to a connection id — `AppletSession.bind(slot:
toConnectionID:)` (T8's seam, the exact write the host view's bind sheet
performs) against that applet's live `ConnectionBindingStore`, persisted
to `<project>/.dreamux/appdata/<slug>/connections.json` (a flat
`{slot: connectionId}` map). Reaches the applet's `AppletSession` via
`ProjectSession.appletSession(for:)` — the same cached instance the host
view binds through once the applet is open — so a driver may call this
before or after `openApplet`; both land on the one live resolver.
Errors when `slug` doesn't match any applet in the project or the
binding write fails.

```
→ {"cmd":"bindConnection","slug":"probe","slot":"github","connectionID":"github"}
← {"ok":true}

→ {"cmd":"bindConnection","slug":"nope","slot":"github","connectionID":"github"}
← {"ok":false,"error":"no applet with slug \"nope\" in this project"}
```

A bound slot takes effect for the applet's `{connection: "<slot>"}`
calls immediately (the binding store is mutated in memory as well as on
disk); it does **not** by itself re-run an already-loaded applet's page
— rewrite `index.html` (even with identical bytes, to bump its mtime)
and let the applet's 1s hot-reload poller pick up the change, or wait
for a fresh `openApplet` on an applet that hasn't been opened yet.

#### `connectionsState`

Metadata snapshot of every connection in the app-wide store — id and
allowlisted hosts only, **never** a token (tokens never leave
`ConnectionStore`/`SecretStore`). Mostly a debugging aid for confirming
`createConnection` landed.

```
→ {"cmd":"connectionsState"}
← {"ok":true,"connections":[{"id":"github","hosts":["api.github.com"]},{"id":"eas","hosts":[]}]}
```

### `courseCorrect`

File a course correction against a plan, driving the same submit as the
sidebar's *Course correct…* sheet (its context-menu entry points can't
be harness-driven, so this command is the only way to exercise the
flow). Writes a tracked **fix-task** into the plan file — `### Task N.k:
Fix — <summary> *(course correction, <date>)*` with a single checkbox
step, at the anchor phase's end (same `CourseCorrection.apply` the sheet
calls) — and, when the plan is **live** (`running`/`awaitingReview`),
parks the priority-worded nudge on the plan's live agent, delivered
under the usual quiescence + gate rail.

`{"cmd": "courseCorrect", "plan": "docs/plans/…md", "text": "…",
"priority": "now"|"next"|"queue", "task"?: "…", "phase"?: "…"}`

- `plan` — the target plan's project-relative path (must match a plan in
  the current doc scan).
- `text` — the observation; its first line becomes the fix-task heading
  summary, the whole text the step body. Must be non-empty.
- `priority` — the nudge wording: `now` (pause the current task, do the
  fix, resume), `next` (finish the current task, then the fix), `queue`
  (pick the fix up in document order).
- `task`? — anchor the fix-task under a specific task, matched by its
  exact heading title or a **unique**, case-sensitive substring.
  Ambiguous or unmatched substrings error.
- `phase`? — anchor under a `## ` phase by name. Ignored when `task` is
  given (a task is the more specific anchor).
- Neither `task` nor `phase` → the fix-task lands in the plan's current
  phase (the plan-row default).

The fix-task is written for any plan; the nudge is parked only for a
live one — an idle/ready/merged plan gets the tracked task and
`nudged: false`. A nudge parked while the plan sits at a merge gate
stays parked (the gate rail), observable as `pendingNudges` on the
plan's `state` entry.

```
→ {"cmd":"courseCorrect","plan":"docs/plans/2026-07-02-x.md",
   "text":"the retry backoff is unbounded","priority":"next",
   "task":"Task 3"}
← {"ok":true,"path":"docs/plans/2026-07-02-x.md","nudged":true}
```

Errors (`{"ok":false,"error":…}`): unknown `plan`, empty `text`, an
invalid `priority` token, and an ambiguous or unmatched `task`.

### `quit`

Reply, then terminate the app (`NSApp.terminate`, with a forced
`exit(0)` backstop ~2s later — graceful AppKit termination can stall
when sheets or live embedded shells are up). The response is flushed
before termination; the connection then drops. Expect process exit
within ~3s of the reply.

```
→ {"cmd":"quit"}
← {"ok":true}
```

### Errors

Any failure — unknown command, missing/invalid parameters, unknown
workspace/repo/runner, no project window yet, git failures —
responds:

```
← {"ok":false,"error":"no workspace named \"nope\""}
← {"ok":false,"error":"unknown command: frobnicate"}
```

The connection stays usable after an error.

## Driver checklist

1. Make per-run sandbox dirs; seed `$DREAMUX_PROJECTS_ROOT/<project>`
   (an empty dir is a valid project) and any local repos to import.
2. Launch the app with the env vars above; retry-connect to the
   socket; `ping` until ok.
3. Poll `state` until `activeProject` is non-null (the auto-opened
   window has registered).
4. Drive the scenario; `screenshot` along the way.
5. `quit`, wait for process exit, tear down the sandbox.
