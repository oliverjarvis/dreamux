# Run Controls, Signals MCP, Commit Trail & Library Batch — Design

**Date:** 2026-07-05
**Status:** Approved (brainstorming session)

## Goal

Six feature groups, delivered and merged in order, each its own branch:

1. **Header run controls** — play/stop + services dropdown in each project's context header.
2. **Signals persistence + dreamux-signals MCP** — service logs persisted to SQLite, exposed to agents via an MCP server (revival of cmux-signals).
3. **Auto-commit per task + commit trail + diffs** — every completed plan task becomes a commit; the git chip and task rows open diff views.
4. **File tree power-ups** — context menu + drag-out (including drag-into-terminal).
5. **Pinned main row** — permanent entry at the top of Plans & Specs that activates a main-branch workspace.
6. **Skills & MCPs page** — read-only "library" view of skills, MCP servers, and plugins the agent can access.

## Verified facts this design depends on

- **Run subsystem already exists.** `RunnerManager` (Sources/Dreamux/Models/RunnerManager.swift) parses `.dreamux/run.toml` (hand-rolled TOML: `name, cwd, start, stop, port, port_env, open`), starts/stops/restarts runners with process-group cleanup, allocates ports per worktree via `port_env` + bind probes, and already pipes stdout/stderr into `SignalStore.appendChunk`. `RunSetupView` (Views/RunSetupView.swift) is the Claude-driven discovery UI ("Detect Run Config" prompt writes `run.toml`; also "Isolate on own port" and "Diagnose" flows). The main pane already has a `.run(workspaceID)` mode (ContentView.swift `mainPane`).
- **SignalStore is in-memory only.** `Sources/Dreamux/Models/Signal.swift`: `SignalEntry` (monotonic id, timestamp, source, level, message), 10k-cap ring buffer, per-source line buffering. `SignalsView` is the Datadog-style explorer; `.signals` is a `SidebarTile`. One `SignalStore` per `ProjectSession` (ProjectSession.swift).
- **cmux-signals recovered.** `~/Development/cmux-main/mcp/cmux-signals-mcp.ts` — bun + `@modelcontextprotocol/sdk` stdio server. Read path: SQLite `signals.db` opened read-only (schema: `id, source, kind, ts (ms), severity, tags_json, payload_json`), project-scoped by `json_extract(tags_json, '$.project_dir') = cwd`. Write/live path: Unix socket `/tmp/cmux-emit-<bundle-id>.sock`, line-delimited JSON (`{action: "emit", signal}` → ack; `{action: "subscribe", filter, max_events, timeout_seconds}` → push stream). Tools: `signals_recent`, `signals_query`, `signals_kinds_summary`, `signals_sources_summary`, `signals_subscribe`/`unsubscribe`, `signals_emit`. App-side module in `cmux-main/Sources/Signals/`: `Signal` (typed envelope + `SignalPayload` type-erased JSON), `SignalBus`, `SignalStore` (SQLite WAL), `SignalEmitSocketServer`, `ServicesTerminalEmitter` (service pipes → `terminal.line`, health transitions → `service.health`), `MCPInstaller` (merges a server entry into a project's `.mcp.json`; prefers bundled compiled binary, falls back to resolved bun + `.ts`; absolute bun path required because Claude Code spawns MCP servers with a stripped PATH).
- **Stale config:** clayspace's `.claude/settings.local.json` lists `cmux-signals` under `disabledMcpjsonServers`.
- **Task lifecycle.** Plans are markdown docs (`PlanDoc` with `PlanTask` = `### Task N:` heading, `PlanStep` = checkbox). Status is derived (PlanStatus.swift); `PlanQueueController.tick()` observes checkbox transitions and gates merges. `PlanRunCoordinator.runPlan()` provisions worktrees and sends the agent prompt via `ClaudePromptDriver`. No commit is made per task today.
- **Git plumbing.** `GitOperations` has `commitAll`, `hasUncommittedChanges`, `headStatus` (→ git chip), `worktreeURL(forBranch:)`, `changedTopLevelPaths`, merge/probe helpers. No commit-log or file-content diff helpers yet.
- **Git chip.** ContentView contextHeaderRow renders branch/short-SHA/+N −M from a 5s-polled `GitHeadStatus`; it is display-only.
- **File tree.** `FileTreePanel` rows have no context menu and no drag support. Files open Monaco tabs via `onOpenFile`. Terminal input goes through `TabSession.send(_:)` (PTY write); `HostedTerminalView` has no drop handling.
- **Monaco is embedded** (WebKit + scheme handler, `editor-boot.js`); Monaco ships a side-by-side diff editor (`createDiffEditor`), currently unused.
- **Sidebar order** (WorkspaceSidebar `content`): tiles (Signals, Browser) → Orchestration Files → `PlansSpecsSection` → Repositories. Features as a standalone list are retired; plans are the work items. `SidebarTile` is a `CaseIterable` enum persisted by raw value.
- **Default branch is invisible.** `RepoStore.discoverFeatures()` filters out default-branch worktrees; depending on history a repo may have no main worktree at all (bare layout: `repos/<repo>/.bare` + per-branch worktrees). Sessions can start at any path via `WorkspaceSession.openAgentTab(at:)`.
- **Skills layout.** `SkillLinker` fans project skills (`<project>/.agents/skills`, `.claude/skills`) into repos/worktrees with `.git/info/exclude` entries. The approved 2026-06-12 skills.sh spec covers registry browsing/installing; its placement decision ("OuterRail") predates the current sidebar and is superseded by this design's Skills & MCPs page.

## Decisions (user-approved)

1. **Auto-commit = agent commits + app backstop.** The plan-run prompt instructs the agent to commit after each task; the app commits leftovers when it observes a task complete or the plan reach review.
2. **Delivery = merge per group**, in the numbered order above.
3. **Main entry = permanent, non-dismissible row at the top of Plans & Specs**, styled as a place (workspace-like), not a plan row. Activating it materializes main worktrees on demand.
4. **Rename `cmux-signals` → `dreamux-signals`** (server name + script + socket/db discovery); tool names stay `signals_*`. Clean up the stale disabled entry.
5. **Skills & MCPs v1 is read-only browsing**; skills.sh registry integration stays deferred (see 2026-06-12 spec for when it lands — it will live inside this page).

---

## Group 1 — Header run controls + services dropdown

**UI.** A run cluster in `contextHeaderRow`, left of the git chip:

- **Play capsule.**
  - No `run.toml` for the project → clicking sets `sidebarMode = .run(activeWorkspaceID)` (existing discovery UI). Tooltip: "Set up run configuration".
  - Config exists, nothing running → `play.fill`; click starts all runners scoped to the active workspace's worktree (existing `RunnerManager.start` semantics, `port_env` concurrency included).
  - Anything running → stop square + count label ("2 running") + green pulsing status dot; click stops the active scope's runners. Failure state (any runner failed) shows an amber dot.
- **Chevron** (separate hit target) → popover:
  - One row per configured runner for the active scope: status dot (running/starting/failed/stopped), name, resolved port (monospaced). Hover actions: open-in-browser (globe; enabled when a port or `open` URL is known — builds `http://localhost:<port>` when only a port exists), restart, stop/start, "logs" (sets `sidebarMode = .signals` with the source filter preselected).
  - If runners belonging to *other* worktrees are alive, they appear under a second "Other worktrees" group with the same rows — nothing running is invisible.
  - Footer: Start all · Stop all · Edit run config (→ `.run` pane).

**Plumbing.** `RunnerManager` already exposes status per instance; add whatever small published aggregates the header needs (running count / any-failed for the active scope). `SignalsView` gains a preselected-source entry point (it already has source chips).

## Group 2 — Signals persistence + dreamux-signals MCP

**Persistence.** Port the cmux architecture into Dreamux:

- New SQLite-backed store (WAL) at `~/Library/Application Support/<bundle-id>/signals.db`, cmux-compatible schema: `id TEXT, source TEXT, kind TEXT, ts INTEGER(ms), severity TEXT, tags_json TEXT, payload_json TEXT`.
- The existing in-memory `SignalStore` stays the UI's hot path; every appended line also writes through as a `terminal.line` signal with tags `project_dir` (worktree/project path), `project`, `service`, `stream`, and payload `{text, stream}`. Runner health transitions emit `service.health` (port of `ServicesTerminalEmitter`, no-op when status unchanged).
- On launch, hydrate the ring buffer with the most recent rows for the project so Signals survives restarts.
- Retention: cap the table (delete oldest beyond ~200k rows, checked periodically) so the DB can't grow unbounded.

**Emit socket.** Port `SignalEmitSocketServer`: Unix socket at `/tmp/dreamux-emit-<bundle-id>.sock`, line-delimited JSON, actions `emit` (ack `{ok, id}`) and `subscribe` (filter by kind/source/project_dir; pushes `{signal}` lines). Signals arriving via `emit` flow through the same path as internal emitters (persisted + published to the in-memory store, so they appear in SignalsView live).

**MCP server.** Vendor the script as `mcp/dreamux-signals-mcp.ts`, adapted: server name `dreamux-signals`; DB discovery under Dreamux's Application Support; env overrides `DREAMUX_SIGNALS_DB`, `DREAMUX_PROJECT_DIR`, `DREAMUX_SIGNALS_ALL_PROJECTS`, `DREAMUX_SIGNALS_EMIT_SOCKET`; tool names unchanged (`signals_recent/query/kinds_summary/sources_summary/subscribe/unsubscribe/emit`).

**Installer.** Port `MCPInstaller`: idempotently merge a `dreamux-signals` entry into `.mcp.json` at agent-session working directories (project root for planning sessions, feature dir for plan runs), preserving other servers, never clobbering malformed JSON. Resolution order: bundled compiled binary (future) → repo `.ts` via absolute bun path (probe `~/.bun/bin`, Homebrew paths, asdf installs). Called from session-start paths; a manual re-install affordance lives in SignalsView's header. Remove the stale `cmux-signals` entry from `.claude/settings.local.json`.

**Agent awareness.** The plan-run prompt gains one line telling the agent the `dreamux-signals` MCP exists: query recent service logs when debugging, and `signals_emit` findings worth surfacing.

## Group 3 — Auto-commit per task + commit trail + diffs

**Auto-commit.**
- Prompt: after finishing a task and checking its boxes, the agent runs, in each repo worktree it touched, `git add -A && git commit -m "Task N: <title>"`.
- Backstop: when `PlanQueueController.tick()` observes a task transition to fully-checked, or the plan reach `.awaitingReview`, and `hasUncommittedChanges` in a feature worktree, the app runs `commitAll` with message `Task N: <title> (auto)` (or `Plan review checkpoint (auto)` at review time when no single task boundary applies).
- **Settings toggle:** "Commit after each task" in a new **Workflow** section of the Settings window (alongside Appearance), `@AppStorage`-backed, default **on**. Off disables both halves — the prompt instruction is omitted and the backstop never commits. `PlanRunCoordinator` reads it when building the prompt; `PlanQueueController` reads it per tick, so flipping it mid-plan takes effect from the next task boundary. The commit-trail popover and task diffs (below) remain available either way — with the toggle off they simply reflect whatever commits the agent chose to make.
- **Accepted races (v1):** the backstop may front-run the agent's commit (the "(auto)" commit wins; the prompt tells the agent to continue past "nothing to commit"); a backstop `git add -A` may scoop early edits of the next task within the 3s poll window; index.lock collisions log and skip.

**Git plumbing.** `GitOperations` additions:
- `commitLog(in:baseBranch:limit:)` → `[CommitInfo]` (`sha`, `shortSHA`, `subject`, `authorDate`, `insertions`, `deletions`) via `git log --numstat --format=…` from `baseBranch..HEAD` (falling back to recent HEAD history on main, where the range is empty).
- `changedFiles(from:to:in:)` → `[(status, path)]` via `git diff --name-status A..B`.
- `fileContent(at:revision:in:)` → String via `git show REV:path` (nil for binary/missing sides).

**Commit trail (git chip).** The chip becomes a button → popover: commit list newest-first (subject, short SHA, `+N −M`; `Task N:`-prefixed subjects get a small checkmark badge). Row click → diff of that commit vs its parent. Header actions: "Diff vs <default branch>" (whole branch), "Copy SHA" per row via context menu. Uncommitted changes, when present, appear as a synthetic top row ("Uncommitted changes") diffing worktree vs HEAD.

**Diff viewer.** New read-only tab type (sibling of `FileEditorTabSession` modes): left rail lists changed files with status letters; selecting one loads original/modified into a Monaco **diff editor** (side-by-side; `editor-boot.js` grows a diff mode). Tab title like `abc1234 → def5678` or `Task 3 changes`.

**Task rows.** In `PlansSpecsSection`, task rows get a hover button + context-menu item "View changes": resolves the commit(s) whose subject matches `Task N:` for that plan's feature worktrees and opens the diff viewer for that range (single commit → vs parent; several → first-parent..last). When no matching commit exists yet, the item is disabled with an explanatory tooltip.

## Group 4 — File tree power-ups

**Context menu** on every row (`FileTreePanel`):
- Files: Open · Reveal in Finder · Copy Path · Copy Relative Path · Rename… · Move to Trash.
- Folders: the same, plus New File…, New Folder…, and Open in Terminal (sends a shell-escaped `cd '<path>'` to the active tab via `TabSession.send`).
- Rename/New use small inline sheets; Move to Trash uses `NSWorkspace.recycle` (recoverable, no confirm dialog).

**Drag.** Rows export their file URL (`NSItemProvider` / `.onDrag`) — drags to Finder, editors, browsers work natively. The terminal container gets an `onDrop(of: [.fileURL])` handler that types the shell-escaped path (space-suffixed) into the focused tab, matching Terminal.app muscle memory. The file tree refreshes after rename/trash/create.

## Group 5 — Pinned main row

**UI.** Permanent first row of the Plans & Specs section, above initiatives, not dismissible or reorderable. Styling: place-not-plan — branch glyph (`arrow.triangle.branch`), label `main` (the actual default branch name), subtle tint, no status glyph/progress. Selected state matches workspace selection styling. Subtitle shows the repos it spans when the project has more than one.

**Behavior.** Clicking activates the **main workspace**, a reserved pseudo-workspace:
- Flagged (`isMain`) so feature discovery, close/merge gates, and plan machinery skip it; it is never listed as a feature and never persisted as one.
- Working directory = project root; file tree roots = each repo's default-branch worktree; git chip polls the default-branch worktree; run controls (Group 1) operate on main's worktree scope.
- **Worktree on demand:** on first activation per repo, if no worktree exists for the default branch, run `git worktree add repos/<repo>/<defaultBranch> <defaultBranch>` (via `GitOperations`). Failures surface inline in the row (tooltip + warning tint), not as a modal.
- A Claude session on main is just opening a tab there — no special affordance needed beyond the workspace surface.

## Group 6 — Skills & MCPs page

**Entry.** New `SidebarTile` case `.library`, label "Skills & MCPs", symbol `puzzlepiece.extension`, teal tint, rendered below Signals/Browser (existing tiles code path; enum is CaseIterable so it appears automatically). New `sidebarMode` case routes the main pane to the page.

**Scanning (read-only, local filesystem + config parse):**
- **Skills:** `<project>/.agents/skills` + `<project>/.claude/skills` (project), `~/.claude/skills` + `~/.agents/skills` (global), plugin-bundled skills under `~/.claude/plugins/cache/<marketplace>/<plugin>/<ver>/skills`. Name + description from SKILL.md frontmatter.
- **MCP servers:** project `.mcp.json` (and feature-dir `.mcp.json`s), global `~/.claude.json` `mcpServers`, plugin-provided servers from plugin manifests.
- **Plugins:** `~/.claude/plugins` installed set (marketplace cache + config).
- **Agent access** computed per item: exists ∧ not disabled (`.claude/settings*.json` `disabledMcpjsonServers` / skill enablement) ∧ in a location the agent's session cwd can discover (project skills only count when SkillLinker fan-out or repo placement makes them reachable from worktrees).

**UI.** App-Store-ish library: search field; sections **Skills / MCP Servers / Plugins** as card grids. Card: kind icon, name, one-line description, scope badge (Project / Global / Plugin: <name>), access badge (green "Agent access" / gray "Not accessible" with reason tooltip). Click → detail panel (inspector-style within the page): full description, contents (skill file list; MCP command + declared tools when statically known), path + Reveal in Finder, and for MCP servers the enabled/disabled source that produced its status. No install/uninstall/toggle in v1. A quiet footer notes "Browse skills.sh — coming soon" as the hook where the 2026-06-12 design lands.

---

## Testing

Per group, unit tests alongside the existing suites: header run-state aggregation; SQLite store round-trip + retention + socket protocol framing; MCP installer merge semantics (preserve/refresh/skip-malformed); `commitLog`/`changedFiles` parsing (incl. binary `-` numstat lines); task→commit resolution; file-tree operations (rename/trash/create); skills/MCP scanners against fixture directories; main-worktree materialization. UI verified per the established screenshot workflow (window-ID capture + pixel sampling). Full test suite green before each group's merge.

## Delivery

One branch per group, merged to main in order 1→6 (ff-only where possible, per repo conventions). Each merge leaves the app relaunched from main.
