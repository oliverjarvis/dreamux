# Flows — Live Agent-Run Observatory — Design

**Date:** 2026-07-06
**Status:** Approved (brainstorming session)

## Goal

A live graph view of everything the project's agents are doing. Every run — plan
executions, Claude workflows, subagent fan-outs, scheduled/background loops — is
modeled as a DAG with a source and a drain, rendered as lanes in a new **Flows**
pane. The view answers three questions at a glance: *what is running in
parallel*, *what is blocked on me*, and *what is stuck in a loop* — the last one
via a live iteration badge on repeating steps (e.g. a failing test → edit →
test cycle). Five delivery groups, each its own implementation plan and merge.

Integration is observation-only against **interactive** Claude Code sessions:
no `claude -p`, no driving the CLI programmatically. Data comes from claude's
on-disk surfaces plus hooks injected by the existing PATH shim.

## Verified facts this design depends on

Claude Code surfaces (verified empirically against claude 2.1.201 on
2026-07-05 and against the official hooks reference; see memory
`claude-code-observability-surfaces`):

- **Session registry.** `~/.claude/sessions/<pid>.json`, one per running
  claude process: `{sessionId, cwd, status: idle|busy|waiting, name, kind:
  interactive|bg, updatedAt, version}`. Updates in real time. `waiting` means
  blocked on the human (permission prompt or input).
- **Transcripts live-append.** `~/.claude/projects/<cwd-slug>/<session-uuid>.jsonl`.
  One JSON object per line; an assistant response with multiple content blocks
  becomes multiple lines sharing `message.id` (group to rebuild a turn);
  `uuid`/`parentUuid` chain the message DAG. Entry `type`s observed: `user`,
  `assistant`, `system`, `attachment`, `file-history-snapshot`, `ai-title`,
  `last-prompt`, `mode`, `permission-mode`, `summary`, `queue-operation`,
  `worktree-state`, `relocated`. Format is internal — parse defensively.
- **Subagents get their own files.**
  `projects/<slug>/<parent-session-uuid>/subagents/agent-<id>.jsonl` plus
  `agent-<id>.meta.json` = `{agentType, description, toolUseId, spawnDepth}`.
  `meta.toolUseId` matches the `Agent` tool_use block in the parent transcript;
  the subagent's result returns as the parent `tool_result` with the same id.
  Spawn edge, lifetime, and drain are all explicitly recorded. Oversized tool
  outputs spill to `<session-uuid>/tool-results/*.txt` (observed up to 48 MB).
- **Tasks are a dependency graph on disk.** `~/.claude/tasks/<session>/<n>.json`
  with `blocks`/`blockedBy` arrays.
- **Hooks.** 31 events including `SubagentStart`/`SubagentStop` (matcher on
  agent type; stdin JSON includes `agent_id`, `agent_type`, `session_id`,
  `transcript_path`, `cwd`), `TaskCreated`, `TaskCompleted`, `Stop`,
  `SessionEnd`. Hook types include `command` (supports `async: true`) and
  native `http`. Hooks are registered per-invocation via `--settings` — which
  the Dreamux shim already does.
- **Workflow runs** persist their script (whose `meta` block declares name and
  phases) and a `journal.jsonl` of per-agent return values under the session
  directory. Workflow agents are ordinary subagents, so subagent hooks and
  files fire for them. Journal format is undocumented.
- **Background/scheduled work** (crons, `/loop`) runs via an internal daemon;
  `~/.claude/jobs/<id>/state.json` + `timeline.jsonl` exist but are volatile
  internals. Background sessions do appear in the registry with `kind:"bg"`.
- **No attach API exists.** Tail-plus-hooks is the established pattern for
  every Claude Code observability tool. (opencode is server-as-hub with an SSE
  event stream; codex writes rollout JSONL — future adapters, out of scope.)
- **Secrets to never read:** `~/.claude/ide/*.lock` (live WebSocket authToken),
  `~/.claude/daemon/control.key`.

Dreamux facts:

- **The shim owns hook injection.** `Tools/claude` (bundled, PATH-prepended)
  execs real claude with inline `--settings` wiring `Stop`/`Notification` to
  `Tools/dreamux-hook`, which emits OSC-9 through the PTY. Nothing is written
  to `~/.claude` or project `.claude/`. Opt-out `DREAMUX_CLAUDE_INTEGRATION=0`;
  every failure path falls back to a clean exec of real claude.
- **Signals bus.** MCP/socket → `SignalBus` → SQLite (WAL,
  `~/Library/Application Support/<bundle-id>/signals.db`) → Combine fan-out to
  `SignalsView`. Emit socket: `/tmp/dreamux-emit-<bundle-id>.sock`,
  line-delimited JSON (`{action:"emit", signal}` → ack).
- **File watching.** `DocStore.rebuildWatchers` is the house kqueue pattern:
  `open(O_EVTONLY)` + DispatchSource `[.write,.extend,.rename,.delete]`,
  debounced. `PlanQueueController.startPolling` is the house 3 s poll loop.
- **Plan state already exists.** `PlanQueueController` (idle/running/atGate/
  attention, `mergeAndContinue`), `PlanRunLedger`, `PlanPhases`,
  `WorkspaceSession.agentTabSession` (which terminal tab the agent runs in),
  `allShellsQuiescent` (idle probe).
- **Sidebar pattern.** `SidebarTile` enum (signals, browser, library) +
  `SidebarMode` (workspace, run, signals, library) + `mainPane` arm; the
  Library tile (2026-07-05) is the freshest worked example.
- **e2e.** Unix-socket NDJSON server, `E2ERegistry` handles, in-process
  `cacheDisplay` screenshots (native views capture; Ghostty surfaces render
  blank), scenarios in `Scripts/e2e/driver.py`.

## Decisions (user-approved)

1. **One batch spec, five delivery groups**, each with its own implementation
   plan and merge (the run-controls-batch pattern).
2. **Hook events ride the signals bus.** `dreamux-hook` gains a second sink
   (emit socket) and the events become real Signals with new `SignalKind`s —
   persisted, visible in SignalsView, replayable. `FlowStore` subscribes via
   the existing Combine fan-out and replays recent signals on launch to
   rebuild lanes across app restarts.
3. **Additive.** PlansSpecsSection keeps all rows and controls; plan rows gain
   only a small status dot fed by FlowStore. No consolidation in this spec.
4. **CLI-agnostic model, single adapter.** FlowGraph types carry no Claude
   vocabulary; all Claude parsing lives in `ClaudeFlowAdapter`. No adapter
   protocol until a second CLI actually lands.
5. **Tail the hot set only.** Continuous transcript tailing is limited to
   sessions the registry reports `busy`/`waiting` (typically 1–4). Idle or
   finished sessions are tailed lazily when zoomed.

---

## Domain model

New files under `Sources/Dreamux/Models/` (one type per concern):

- **`Flow`** — one lane. `id`, `title`, `kind: FlowKind` (`.plan`, `.adhoc`,
  `.scheduled`), `workspaceID: UUID?` (→ worktree + terminal tab),
  `status: FlowStatus`, `startedAt`, `nodes: [FlowNode]`, `edges: [FlowEdge]`.
- **`FlowNode`** — `id`, `kind: FlowNodeKind` (`.source`, `.phase`, `.agent`,
  `.step`, `.task`, `.gate`, `.drain`), `label`, `status: FlowStatus`
  (`.queued`, `.running`, `.waiting`, `.done`, `.failed`), `startedAt`/
  `endedAt`, `counters` (tokens, findings, multiplicity `×k` — a small typed
  bag, not a dictionary of Any).
- **`FlowEdge`** — `from`, `to`, `kind: FlowEdgeKind` (`.sequence`, `.spawn`,
  `.dependency`, `.message`, `.loop`), `label: String?`, `iterations: Int?`
  (loop edges only).
- **`FlowStore`** — `@MainActor ObservableObject`, one per `ProjectSession`
  (constructed in `ProjectSession.init`, registered with `E2ERegistry`).
  Publishes `[Flow]` plus derived aggregates for badges (`runningCount`,
  `needsYouCount`). All mutations arrive as events from the three feeds; the
  store itself contains no parsing.
- **`ClaudeFlowAdapter`** — the only type that knows Claude's file formats and
  hook payloads. Translates raw artifacts into FlowGraph mutations. Pure
  functions where possible (input: JSONL lines / signal payloads / registry
  snapshots; output: mutation values) so fixtures drive unit tests directly.

The claude home root is injectable — `DREAMUX_CLAUDE_HOME` env override,
defaulting to `~/.claude` — so tests and e2e run against synthetic roots.

## Ingestion — three feeds

**1. Registry poll (3 s, house pattern).** Read `$CLAUDE_HOME/sessions/*.json`,
keep entries whose `cwd` is under a project worktree, map cwd → `Workspace`
via `WorkspaceStore`. Provides session liveness, `busy`/`idle`/`waiting` (lane
color + needs-you), `kind:"bg"` (scheduled lanes), and the transcript path
pairing. Stale entries (dead PIDs) are dropped after a liveness check.

**2. Hook signals.** The shim adds `SubagentStart`, `SubagentStop`,
`TaskCreated`, `TaskCompleted` hook registrations (async command hooks →
`dreamux-hook`) alongside today's `Stop`/`Notification`. `dreamux-hook` gains
a second sink: write one JSON envelope to the emit socket via `nc -U`
(silently skipped if the socket or `nc` is unavailable — a hook must never
break the user's session; OSC-9 behavior is unchanged). New `SignalKind`s:
`agent.started`, `agent.stopped`, `task.created`, `task.completed`,
`session.stopped`, and `session.notification` (carries the notification
message — e.g. the permission-request text shown on waiting lanes), each
carrying `session_id`, `agent_id`/`agent_type` where present, and `cwd`.
These persist to signals.db like any signal; `FlowStore` subscribes live and
replays the recent window (24 h, capped at 5,000 signals) on launch so lanes survive app restarts and capture sessions run while the app
was closed.

**3. Hot-set transcript tailer.** For each `busy`/`waiting` session: a kqueue
`.extend` watcher (DocStore pattern) plus a persisted per-file byte offset.
On wake, read from offset to EOF, buffer any partial trailing line, parse
appended lines through the adapter. Watches the session's `subagents/`
directory too — a new `agent-*.meta.json` is the spawn edge
(`toolUseId` ⇄ parent `tool_use` id), and the matching parent `tool_result`
closes the node. Zooming a non-hot flow starts a lazy tail (one read-through,
then follow while the view is open, then stop). Sessions leaving the hot set
keep their offsets so re-entry is incremental.

**Plan lanes reuse plan state.** Lane skeletons for plan runs come from
`PlanQueueController`/`PlanRunLedger`/`PlanPhases` (phases, queue order,
gates) — not re-derived from transcripts. Claude-derived nodes (agents, steps,
loops) nest beneath the phase active when they occurred. Ad-hoc sessions
(agent tab without a plan) get a minimal source→session→drain lane. Scheduled
lanes come from `kind:"bg"` registry sessions plus their transcripts; run
history renders from persisted signals. "Next run at …" appears only if the
version-guarded read of `jobs/<id>/state.json` succeeds — it is garnish, never
load-bearing.

**Guardrails.** Adapter checks envelope `version` and degrades to
skeleton-only on unknown majors. Unknown entry types are skipped and counted.
Inode change (truncate/replace) resets the offset. Line length, replay window,
and inspector reads are size-capped. `tool-results/*.txt` is read only
on demand in the inspector. `ide/` and `daemon/` (except the optional
`jobs/state.json` garnish above) are never read; no secrets are ever logged.

## UI

### Sidebar

`SidebarTile.flows` — icon `point.3.connected.trianglepath.dotted`, amber,
label "Flows", live badge `●3 · !1` (running / needs-you) from FlowStore
aggregates. `SidebarMode.flows` + `mainPane` arm (Library pattern). Plan rows
in PlansSpecsSection gain a leading status dot (`●` running, `!` needs-you,
`↺` scheduled, `○` queued, `✓` merged) — display-only, controls untouched.

### Flows overview (lanes)

```
┌───┬─────────────────────────┬────────────────────────────────────────────────────────────────────┐
│ ◉ │ WORK ITEMS              │ FLOWS                                   ● 3 running · ! 1 needs you│
│ ○ │                         │                                                                    │
│ ○ │ ◆ Signals             12│ auth-refresh                                      12m · claude busy│
│   │ ◆ Browser               │ ◉─▶[ plan ✓ ]─▶[ implement ● ]─▶[ test ○ ]─▶[ gate ]─▶◎ merge      │
│   │ ◆ Flows          ●3 · !1│                  └▸ 3 agents                                       │
│   │ ─────────────────────── │                                                                    │
│   │ FILES                 ▸ │ tree-dnd-fix                             ! waiting on permission 4m│
│   │ PLANS & SPECS         ▾ │ ◉─▶[ plan ✓ ]─▶[ implement ! ]   Bash: npm run e2e → allow?        │
│   │  ● auth-refresh         │                                                                    │
│   │  ! tree-dnd-fix         │ nightly-triage                              ↺ loop · next run 02:00│
│   │  ↺ nightly-triage       │ ◉─▶[ triage ✓ ]─▶[ report ✓ ]─▶◎   ✓ 14 runs · last 01:58          │
│   │  ○ signals-v2           │                                                                    │
│   │  ✓ file-tree-power      │ ● running   ○ queued   ✓ done   ✗ failed   ! needs you   ↺ loop    │
│   │ REPOSITORIES          ▸ │                                                                    │
└───┴─────────────────────────┴────────────────────────────────────────────────────────────────────┘
```

`FlowsOverviewView`: vertical stack of `FlowLaneView`s. Lane = header row
(title, elapsed, session chip) + horizontal source→drain pipeline of node
chips. Order: needs-you, running, queued, recently-done (fades, collapses to a
single row after a few minutes; "show finished" disclosure for history).
Scheduled lanes use the compact recurring form with a run-history strip whose
chips open that run's transcript. Empty state explains what appears here.
Interactions: click lane → zoom; click needs-you chip → jump to that
workspace's terminal tab (`WorkspaceSession.agentTabSession`); hover node →
timing tooltip.

### Zoomed flow (DAG + inspector)

```
┌──────────────────────────────────────────────────────────────┬─────────────────────────────────┐
│ ◀ flows / auth-refresh / implement            ● running 7m12s│ ● review:perf                   │
├──────────────────────────────────────────────────────────────┼─────────────────────────────────┤
│                                                              │ agent a3f2c1 · depth 1          │
│                  ┌──────────────┐                            │ ─────────────────────────────── │
│                  │ session    ● │ claude · busy              │ status    ● running · 1m12s     │
│                  └───────┬──────┘                            │ type      general-purpose       │
│                          │                                   │ model     inherit (fable)       │
│           workflow review-changes · run wf_9f3a              │ tokens    14.2k out             │
│        ┌─────────────────┼─────────────────┐                 │                                 │
│ ┌──────▼─────┐    ┌──────▼─────┐    ┌──────▼─────┐           │ last activity                   │
│ │ bugs     ✓ │    │ perf     ● │    │ security ✓ │           │ › Bash: swift test --filter...  │
│ │        41s │    │      1m12s │    │        38s │           │                                 │
│ └──────┬─────┘    └──────┬─────┘    └──────┬─────┘           │ [ open transcript ]             │
│        │ 3 findings      │                 │ 1 finding       │ [ jump to terminal ]            │
│        └─────────────────┼─────────────────┘                 │                                 │
│                  ┌───────▼──────┐                            │                                 │
│                  │ verify  ○ ×4 │ 4 verifiers queued         │                                 │
│                  └───────┬──────┘                            │                                 │
│                  ┌───────▼──────┐                            │                                 │
│                  │ ◎ synthesize │                            │                                 │
│                  └──────────────┘                            │                                 │
└──────────────────────────────────────────────────────────────┴─────────────────────────────────┘
```

`FlowDetailView`: layered top-to-bottom DAG. **`FlowLayoutEngine`** is a pure
Swift layered/topological placer (rank by depth, order to reduce crossings, no
dependencies) — unit-testable without views. Edges draw in a SwiftUI `Canvas`;
nodes are real SwiftUI views overlaid on the canvas so hover/click/focus and
accessibility come free (node counts are dozens, not thousands). Fan-outs
wider than 6 collapse to one `×k` node, expandable. Workflow fan-out shape
comes from the persisted workflow script's phases; per-agent results from
`journal.jsonl` label edges when parseable. Only `running` nodes pulse;
`accessibilityReduceMotion` disables pulsing. Node selection fills the
fixed-width inspector: status/type/model/tokens, last-activity from the tail,
`[open transcript]` (JSONL in a viewer tab), `[jump to terminal]`.

### Gate cards

```
 auth-refresh
 ◉─▶[ plan ✓ ]─▶[ implement ✓ ]─▶[ gate ▣ ]─▶[ test ○ ]─▶◎ merge
                                      │
                          ┌───────────▼─────────────┐
                          │ waiting: review & merge │
                          │ +412 -87 · 9 files      │
                          │                         │
                          │ [ view diff ]           │
                          │ [ merge & continue ▶ ]  │
                          └─────────────────────────┘
```

A `gate` node in `waiting` renders expanded in both overview and zoom: diff
stat, `[view diff]` (existing diff sheet), `[merge & continue ▶]` →
`PlanQueueController.mergeAndContinue`. No new git machinery — a new front
door to existing actions.

## Loop detection

```
      ┌──────────┐         ┌──────────┐          ┌──────────┐
   ──▶│  edit  ✓ │────────▶│  test  ● │─pass───▶ │ commit ○ │──▶
      └──────────┘         └────┬─────┘          └──────────┘
           ▲                    │
           │       ↺ fail ×4    │
           └────────────────────┘
```

A pure function in `ClaudeFlowAdapter` over each hot session's recent tool
events: normalize every tool call to a signature (tool name + first token of
the Bash command — `Bash:swift-test`, `Bash:npm`), and when the same signature
occurs ≥3 times within a sliding window with failure evidence between repeats
(non-empty stderr or test-failure markers in the `tool_result`), emit a
`.loop` edge with the iteration count between the involved nodes. The count
updates live as the tail advances. Conservative by design: it is a badge, not
a judgment — the UI never claims the loop is stuck. Scheduled lanes (`↺`)
don't use the heuristic; their recurrence is declared.

## Delivery groups

1. **Ingestion spine.** FlowGraph model types, `FlowStore` skeleton, registry
   poll, shim hook additions + `dreamux-hook` socket sink, new `SignalKind`s,
   launch replay, `DREAMUX_CLAUDE_HOME` injection. No new UI beyond the new
   kinds appearing in SignalsView. *Exit:* fixture-driven unit tests prove
   lanes/nodes/status build correctly from recorded artifacts.
2. **Flows pane.** Tile + badge, `SidebarMode.flows`, overview lanes,
   needs-you chips, jump-to-terminal, plan-row status dots, `scenario_flows`
   e2e + screenshots. *Exit:* the at-a-glance board works from skeleton data.
3. **Hot-set tailer + zoom.** Tailer with offsets, adapter transcript parsing,
   subagent joins, workflow-script/journal reading, `FlowLayoutEngine`,
   `FlowDetailView` + inspector. *Exit:* live validation against a real
   multi-worktree afternoon matches terminal reality.
4. **Loop detection.** Signature heuristic, `.loop` edges + badges in overview
   and zoom.
5. **Gate cards.** Expanded gate card wired to diff sheet + `mergeAndContinue`.

Hard orderings only: 1→2, 1→3; 4 and 5 depend on 3 and 2 respectively.

## Failure behavior

Governing rule: **claude's files are untrusted, evolving input — Flows
degrades, never breaks.** Per-line parse failure = skip and count; excessive
skips mark the lane "detail unavailable" while skeleton (registry + signals +
plan state) keeps working. Registry entries for dead PIDs are dropped. Hook
socket writes fail silently (session safety > telemetry). Tailer survives
truncate/rotate via inode checks. The Flows pane never blocks the main thread
on file IO — all reads on a utility queue, mutations hop to `@MainActor`.

## Testing

- **Unit:** fixture-driven adapter tests using real recorded JSONL (the
  2026-07-05 research session's transcript + subagent files — real fan-out,
  real workflow, real tool churn — checked in, redacted, under
  `Tests/DreamuxTests/Fixtures/claude-session/`); `FlowLayoutEngine` geometry
  tests; `FlowStore` tests via `TestSandbox` with a synthetic
  `DREAMUX_CLAUDE_HOME` root.
- **e2e:** `scenario_flows` writes a synthetic registry + transcript into the
  injected home, opens the Flows pane, screenshots overview and zoom (native
  SwiftUI — captures fine), asserts lane/node state via a new `flowsState`
  E2E command registered through `E2ERegistry`.
- **Live validation:** Group 3's exit criterion above.

## Non-goals

- No codex/opencode adapters (model is CLI-agnostic; adapters wait for demand).
- No OpenTelemetry (aggregate-oriented; wrong tool for a live per-node UI).
- No driving claude from the graph beyond existing plan actions — the graph
  observes; gates reuse `PlanQueueController`; typing stays in the terminal.
- No dependence on `~/.claude/daemon/`/`jobs/` internals beyond the
  version-guarded "next run" garnish.
- No PlansSpecsSection consolidation (revisit once Flows proves itself).
