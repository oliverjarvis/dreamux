# Skills.sh Integration — Design

**Date:** 2026-06-12
**Status:** Approved (brainstorming session)

## Goal

Let users browse the skills.sh registry, preview a skill's files before installing, install skills, and manage what's installed — at two scopes: per Clayspace project and global (user-level). Installs always go through the `npx skills` CLI and always target at least the `claude-code` and `codex` agents.

## Verified facts this design depends on

- **CLI:** `npx -y skills` (package `skills`, vercel-labs). Relevant commands:
  - `add <owner/repo> -s <skill...> -a <agent...> [-g] [-y] [--copy] [-l]`
  - `list --json [-g] [-a <agent...>]` — machine-readable installed list
  - `remove [-s <skill...>] [-a <agent...>] [-g] [-y]`, `update [-g|-p] [-y]`
  - `find <query>` — works non-interactively but outputs ANSI text (not used; see Registry API)
- **Registry API:** the full `skills.sh/api/v1/*` API requires Vercel OIDC auth (unusable from a desktop app). The CLI itself uses a **public** endpoint: `GET https://skills.sh/api/search?q=<query>&limit=<n>` → JSON `{skills: [{id, skillId, name, source, installs}], ...}`. Minimum query length 2. There is no public "list all / leaderboard" endpoint.
- **CLI on-disk layout:** canonical skill copies go to `.agents/skills/<name>/` (project) or `~/.agents/skills/<name>/` (global, `-g`), with per-agent symlinks (e.g. `.claude/skills/<name>` → `../../.agents/skills/<name>`) and a `skills-lock.json` lockfile next to the canonical dir.
- **Claude Code skill discovery:** project skills load from `.claude/skills/` in the starting directory and parent directories **up to the repository root** (plus nested dirs on demand). Discovery does **not** continue above the repo root. Since Clayspace agents start inside repos/worktrees, skills placed only at the Clayspace project root would never be discovered — this forces the symlink fan-out below.
- **Node dependency:** `npx` requires a working node. Failure mode observed on this machine: asdf shims on PATH but no global nodejs version set → `npx` exits with "No version is set for command npx".

## Decisions (user-approved)

1. **Local scope = Clayspace project.** One install covers every repo and feature worktree under the project. No per-repo installs.
2. **Browse = search + topic shelf.** Search field backed by the public search API; front page shows topic chips that run seeded searches (initial set: React, Next.js, Testing, Design, Docs, Git, Security) and a pinned shelf of known-good sources (initial set: `vercel-labs/agent-skills`, `anthropics/skills`; both lists are plain constants, trivially editable later). No scraping.
3. **Agents: claude-code + codex locked on**, with optional checkboxes for additional CLI-supported agents per install.
4. **Node: detect + guide.** Probe for a working node; clear fix-it UI if absent. No bundled runtime.
5. **Placement: "Skills" section in the project window's OuterRail** (alongside "Features"); global scope is the same browser in a dedicated `Window` scene opened from a Home toolbar button.
6. **Architecture: hybrid.** Public search API for browsing, shallow git clone for file preview, `npx skills` for all mutations and the installed list.
7. **Browser layout (option A):** sidebar lists installed skills for both scopes (always visible, management lives there); main area is search/browse; selecting any skill (result or installed) opens a detail view with file tree + file preview + install/update/remove controls.

## Architecture

Three independent data paths:

| Operation | Mechanism |
|---|---|
| Browse / search | `URLSession` → `https://skills.sh/api/search` (public JSON) |
| File preview | depth-1 git clone of the skill's source repo (existing `GitOperations`) into `~/Library/Caches/Clayspace/skill-previews/<owner>-<repo>/` |
| Install / list / remove / update | `npx -y skills …` via detected node, `Process` + continuation pattern (as in `GitOperations`) |

### Scope mechanics

**Global:** `npx skills add … -g`. The CLI manages `~/.agents/skills` + `~/.claude/skills` symlinks; agents pick these up everywhere. Nothing for Clayspace to wire.

**Project:** `npx skills add …` with cwd = project root. Canonical copy lands in `<project>/.agents/skills/`, lockfile at `<project>/skills-lock.json`. Because agent skill discovery stops at the repository root, Clayspace then **fans out symlinks** into every repo working copy and every feature worktree:

```
<project>/
├── .agents/skills/<skill>/          ← canonical (CLI-managed)
├── .claude/skills/<skill>           ← symlink (CLI-created)
├── skills-lock.json
├── repos/<repo>/.claude/skills/<skill>   ← symlink (Clayspace)
│   repos/<repo>/.agents/skills/<skill>   ← symlink (Clayspace)
│   repos/<repo>/.git/info/exclude        ← + per-skill entries (Clayspace)
└── features/<feature>/<repo>/…           ← same links in each worktree
```

- Links use `.git/info/exclude` (local-only) so worktrees and repos stay free of git status noise; tracked files are never modified.
- Worktree creation (already Clayspace-controlled) runs the same linking step, so new features inherit project skills automatically.
- Reconciliation is idempotent: repairs stale links, removes orphans after uninstall, and **never overwrites a repo-owned (committed) skill of the same name** — it skips and reports instead.

## Components

### Models
- `Models/SkillsStore.swift` — `@MainActor @Observable final class SkillsStore`, one instance per scope. Project windows create `SkillsStore(scope: .project(projectURL))` (alongside `WorkspaceStore`/`RepoStore` in `ProjectWindowContents`); the global window creates `SkillsStore(scope: .global)`. State: installed skills, search text/results/phase, in-flight operation, node status.
- `Models/SkillTypes.swift` — `RegistrySkill` (from search API), `InstalledSkill` (from `list --json`: name, source, agents, scope, canonical path), `SkillScope` (`.global` / `.project(URL)`).

### Shell
- `Shell/SkillsRegistryClient.swift` — search API client. Base URL from `CLAYSPACE_SKILLS_API_BASE` when set (e2e), else `https://skills.sh`.
- `Shell/SkillsCLI.swift` — builds and runs `npx -y skills …` (binary overridable via `CLAYSPACE_SKILLS_BIN`); async, cancellable, streams output lines. Contains `NodeDetector`.
- `Shell/SkillPreviewCache.swift` — clone-or-reuse (24h TTL, manual refresh), returns file tree + file contents.
- `Shell/SkillLinker.swift` — project-scope fan-out + `.git/info/exclude` maintenance; called after every mutation and from worktree creation.

### Views
- `OuterRail` gains a `Skills` section (currently only `Features`).
- `Views/SkillsBrowserView.swift` — sidebar (installed: project section + global section) + main area (search field, topic chips, pinned sources, results list).
- `Views/SkillDetailView.swift` — file tree, file preview (SKILL.md first), install controls: scope is implicit (project window → project, global window → global), agents = claude-code + codex locked, extras optional; update/remove for installed skills.
- Global: `Window("Skills", id: "global-skills")` hosting `SkillsBrowserView(scope: .global)`, opened from a Home toolbar button.

## Operation flows & error handling

- **Node detection:** on first entering a Skills section: `zsh -lc 'command -v node'`, then *execute* `node --version` to verify (catches broken asdf shims). Fallback probes: newest of `~/.asdf/installs/nodejs/*/bin/node`, `~/.nvm/versions/node/*/bin/node`, `/opt/homebrew/bin/node`, `/usr/local/bin/node`. Cached per launch. Unresolved → banner with concrete remedies; mutations disabled, browse/preview still work.
- **Search:** debounced ~300ms, min 2 chars; failures show inline error + Retry, keeping last good results.
- **Preview:** spinner during clone; failure → inline error + "Open on skills.sh" link.
- **Install:** `npx -y skills add <source> -s <skill> -a claude-code codex [extras] [-g] -y`, cwd = project root for project scope. Output streams into the project's `SignalStore`. Success → refresh `list --json` → `SkillLinker` reconcile. Failure → alert with first stderr line + expandable raw output.
- **Remove/update:** same shape (CLI → refresh → reconcile).
- **Concurrency:** CLI mutations serialize per scope; controls disabled while one runs.

## Testing

- **Unit:** `SkillLinker` reconcile on temp project trees (creation, idempotency, exclude maintenance, repo-owned skip, orphan cleanup); `list --json` parsing fixtures; `NodeDetector` ordering incl. broken-shim case; `SkillsRegistryClient` via `URLProtocol` stub.
- **Integration:** `SkillsCLI` against a fake `skills` executable in `Tests/Fixtures/bin/` (records argv, fabricates skill dirs + lockfile) — asserts exact flags/cwd. Preview cache against a local bare repo fixture.
- **E2E:** local HTTP stub for the search API (`CLAYSPACE_SKILLS_API_BASE`) + fake CLI (`CLAYSPACE_SKILLS_BIN`); script in `Scripts/e2e/`: open project → Skills section → search → preview files → install → assert links + excludes on disk → screenshots at each stage. New `E2ECommands`: `skillsSearch`, `skillsInstall`, `skillsList`, `skillsRemove`.

## Out of scope

- Authoring/publishing skills (`skills init`), `skills use` one-shot prompts.
- The auth-gated v1 API (leaderboard, curated, audits). If skills.sh later opens it up, the topic shelf can be replaced by a real leaderboard without touching install/manage paths.
- Per-repo install scope.
- Bundling a node runtime.
