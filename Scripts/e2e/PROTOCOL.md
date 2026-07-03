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
| `DREAMUX_CLAUDE_BIN` | Absolute path to the `claude` binary the Run pane's Detect / Isolate / Diagnose buttons paste into their embedded terminal (it is shell-quoted for you). Point it at `Tests/Fixtures/bin/claude` for deterministic agent behavior regardless of the user's PATH/zshrc. When unset, the bare word `claude` is used. |
| `DREAMUX_GH_BIN` | Absolute path to the `gh` binary used by the merge sheet's "Create PR" path (`publishFeature`, `featurePRStatus`, and the sheet's own PR pre-check/polling). Point it at `Tests/Fixtures/bin/gh` — a fake that works against a **local bare repo as origin**, storing PR records inside the remote under `fake-prs/<branch>.json` and deriving MERGED from ref ancestry — so PR scenarios run with no network and no GitHub account. When unset, `gh` from PATH is used. |

A typical harness launch:

```sh
DREAMUX_E2E_SOCKET=/tmp/dreamux-e2e.sock \
DREAMUX_E2E_AUTOOPEN=demo \
DREAMUX_PROJECTS_ROOT=/tmp/dreamux-e2e/projects \
DREAMUX_STATE_DIR=/tmp/dreamux-e2e/state \
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

Commands that touch project state operate on **the most recently
opened project window** (registered when its window appears,
unregistered when it disappears). Single-window runs — the normal e2e
shape, via `DREAMUX_E2E_AUTOOPEN` — never notice. Commands fail with
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
       "webTabs":["http://localhost:4600/"]}
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
    ]
  }
```

Field notes:

- `projects` lists every project the `ProjectStore` discovered under
  the projects root; `activeProject` is the targeted window's project,
  or JSON `null` when no project window is registered.
- `workspaces[].isActive` — the workspace currently selected in the
  sidebar.
- `runners` mirrors the parsed `run.toml`. `cwd`, `port`, `portEnv`
  are **omitted** when absent. `instances` holds one entry per
  (runner, branch) the manager has ever started this session:
  `status` is `"idle" | "running" | "exited" | "failed"`, with `pid`
  (running), `exitCode` (exited), `error` (failed), and
  `assignedPort` (port-env-isolated instances while live) present
  only when applicable.
- `runToml` is omitted when the file doesn't exist
  (`runTomlExists: false`).
- `sidebarMode` is `"workspace" | "run" | "signals"` — the pane the
  project window currently shows.
- `openedTargets` — every `open` target the runner manager fired this
  session, in order (a runner's `open` value with `{port}` resolved to
  the instance's effective port). URL targets open as in-app browser
  tabs in the branch's workspace (reported per-workspace via
  `workspaces[].webTabs`); in e2e mode the EXTERNAL fallbacks
  (browser/shell command) are suppressed, while in-app tabs stay
  enabled and observable.
- `plans` mirrors `DocStore.plans` (docs classified as plans only,
  i.e. not specs/plain docs): `status` is the same derived value
  `listDocs` reports (ledger + checkboxes + feature existence).
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

```
→ {"cmd":"createFeature","name":"feature-x","repos":["webapp"]}
← {"ok":true,"featureDirectory":"…/demo/features/feature-x"}
```

### `setSidebarMode`

Switch the project window's main pane. `mode` is `"workspace"`,
`"run"`, or `"signals"`. The optional `"workspace"` parameter (a
feature name) selects which workspace to activate (for `workspace`
mode) or to scope the Run pane to (for `run` mode; defaults to the
active workspace, then the first one — fails if there are none).

```
→ {"cmd":"setSidebarMode","mode":"run","workspace":"feature-x"}
← {"ok":true}
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
