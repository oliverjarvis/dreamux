# Pinned Main Row Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A permanent, non-dismissible "main" row at the top of Plans & Specs that activates a reserved main-branch workspace — terminal at the project root, file tree on each repo's default-branch worktree (created on demand), git chip and run controls working unchanged.

**Architecture:** `Workspace` gains an `isMain` flag; `WorkspaceStore` gets a find-or-create `mainWorkspace(...)` with a deterministic id, and the main workspace is carved out of feature reload, the ad-hoc partition, order persistence, and removal. `FileTreeStore.roots` resolves the branch folder per-repo (`repo.defaultBranch`) for main workspaces. The row itself lives in `PlansSpecsSection` above the collapsible content, styled as a place (branch glyph + default-branch name), wired through `WorkspaceSidebar`, which materializes missing default-branch worktrees on first activation and surfaces failures inline on the row.

**Tech Stack:** Swift/SwiftPM, SwiftUI, existing `GitOperations.addWorktree/worktreeURL`, XCTest.

## Global Constraints

- Platform floor `macOS(.v14)`; no new dependencies.
- The row is permanent and non-dismissible: no Close, no Merge, not part of drag-reorder; visible even when the Plans & Specs list is collapsed.
- Styled as a place, not a plan: `arrow.triangle.branch` glyph, label = the first repo's `defaultBranch` (falling back to `"main"` with no repos), repos subtitle when the project spans >1 repo, `.callout` typography, selection styling consistent with active-workspace rows.
- Worktree materialization is on-demand at activation, per repo, via the existing `GitOperations.addWorktree(in:branch:)` (which checks out existing branches without `-b`); failures surface inline on the row (warning tint + tooltip), never as a modal.
- Main workspaces are skipped by: feature reload (preserved like orphans), the ad-hoc partition and its drag-reorder splice, `persistFeatureOrder`, `WorkspaceStore.remove` (guarded), and `closeFeature` (guarded, belt-and-braces).
- Known accepted limitation (comment it, don't solve it): a multi-repo project whose repos have *different* default-branch names gets correct file-tree roots (per-repo resolution) but runner branch-scoping uses the workspace's single name — fine for the overwhelming same-name case.
- Tests: XCTest in `Tests/DreamuxTests/`, house style (why-comments, `TestSandbox`/`GitFixtures` where repos are needed). Full `swift test` green before each task's final commit.
- Git: stage only named files (`Scripts/` capital-S); plain-sentence commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Delivery branch `pinned-main-row`; merge only after user approval (Task 4).

**Verified facts this plan builds on (from the current sources):**
- `Workspace` (Models/Workspace.swift:10-39): `id/name/symbol/tint/workingDirectory/linkedRepoIDs`, memberwise init with defaults, Identifiable/Hashable. NOT persisted to disk — `WorkspaceStore.workspaces` is rebuilt via `reloadFeatures(in:repoStore:)` (orphans preserved, discovered features merged, ordered by `layout`), and `registerFeature` derives a deterministic UUID from the name hash.
- `RepoStore.discoverFeatures()` (Models/RepoStore.swift:100-109) already skips default-branch worktrees — main never appears as a feature.
- `GitOperations.addWorktree(in:branch:)` (Shell/GitOperations.swift:277-289): existing branch → `worktree add <branch> <branch>` (path == branch folder under the repo root); `worktreeURL(forBranch:in:)` parses porcelain.
- `resolveGitStatus()` (ContentView.swift:562-578) already falls back to the default-branch worktree — the chip works for main with no changes.
- `FileTreeStore.roots(for:repositories:)` (Models/FileTreeStore.swift:18-36) appends `workspace.name` as the branch folder per linked repo — needs the per-repo default-branch override for main.
- `WorkspaceSidebar`: `closeFeature(_:)` (~line 935) calls `store.remove` with no role check; `adHocWorkspaces` (~line 644) filters only plan-backed names; `featureMenu` gates Merge on `linkedRepoIDs`. `PlansSpecsSection` (Views/PlansSpecsSection.swift) renders header (~line 99) then conditional content on `layout.plansExpanded`; its parameter list already carries `onOpenFeature`, `workspaceForFeature`, `makeRunControls`, `runners`.
- `WorkspaceRunControls(workspace:runners:openServices:start:stop:configure:)` — the shared trailing run cluster; `runners.runningRunners(onBranch:)` drives its stop/play state.

---

### Task 1: Workspace.isMain + store carve-outs

**Files:**
- Modify: `Sources/Dreamux/Models/Workspace.swift`
- Modify: `Sources/Dreamux/Models/WorkspaceStore.swift`
- Modify: `Sources/Dreamux/Views/WorkspaceSidebar.swift` (two one-line guards/filters)
- Test: `Tests/DreamuxTests/MainWorkspaceTests.swift`

**Interfaces:**
- Consumes: existing `Workspace`, `WorkspaceStore` (registerFeature's deterministic-UUID pattern, `reloadFeatures`, `remove`, `persistFeatureOrder`), `AdHocWorkspaces` partition helpers.
- Produces (Tasks 2–3 rely on):
  - `Workspace.isMain: Bool` (defaulted `false` in the memberwise init — every existing call site compiles unchanged)
  - `WorkspaceStore.mainWorkspace(name: String, workingDirectory: String, linkedRepoIDs: [String]) -> Workspace` — find-or-create; deterministic id; appends to `workspaces` on create; never duplicates.

- [ ] **Step 1: Create the working branch**

```bash
cd /Users/olliejarvis/Development/clayspace
git worktree add .claude/worktrees/pinned-main-row -b pinned-main-row
cd .claude/worktrees/pinned-main-row
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/DreamuxTests/MainWorkspaceTests.swift` (read `WorkspaceStore`'s existing test coverage first — `AdHocWorkspacesTests`/`ReorderTests` show the store's test conventions; reuse their arrangement style):

```swift
import XCTest
@testable import Dreamux

/// The reserved main workspace: find-or-create stability, survival
/// across feature reloads, and immunity to removal — the row is
/// permanent, so the workspace behind it must be too.
@MainActor
final class MainWorkspaceTests: XCTestCase {

    private func makeStore() -> WorkspaceStore {
        // mirror however AdHocWorkspacesTests constructs a store
        WorkspaceStore()
    }

    /// Same inputs → same workspace instance (stable id), no duplicates
    /// no matter how often the row is clicked.
    func testMainWorkspaceFindOrCreateIsIdempotent() {
        let store = makeStore()
        let first = store.mainWorkspace(
            name: "main", workingDirectory: "/tmp/proj", linkedRepoIDs: ["web"])
        let second = store.mainWorkspace(
            name: "main", workingDirectory: "/tmp/proj", linkedRepoIDs: ["web"])
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.workspaces.filter(\.isMain).count, 1)
        XCTAssertTrue(first.isMain)
        XCTAssertEqual(first.workingDirectory, "/tmp/proj")
    }

    /// Linked repos can change between launches (repo added to the
    /// project) — find-or-create refreshes them on the existing entry.
    func testMainWorkspaceRefreshesLinkedRepos() {
        let store = makeStore()
        _ = store.mainWorkspace(
            name: "main", workingDirectory: "/tmp/proj", linkedRepoIDs: ["web"])
        let updated = store.mainWorkspace(
            name: "main", workingDirectory: "/tmp/proj", linkedRepoIDs: ["web", "api"])
        XCTAssertEqual(updated.linkedRepoIDs, ["web", "api"])
        XCTAssertEqual(store.workspaces.filter(\.isMain).count, 1)
    }

    /// remove() must refuse the main workspace — nothing in the UI
    /// offers it, but the guard is the invariant, not the UI.
    func testRemoveRefusesMainWorkspace() {
        let store = makeStore()
        let main = store.mainWorkspace(
            name: "main", workingDirectory: "/tmp/proj", linkedRepoIDs: [])
        store.remove(main)
        XCTAssertTrue(store.workspaces.contains { $0.id == main.id })
    }
}
```

Plus one reload-survival test — read `reloadFeatures(in:repoStore:)`'s real signature/arrangement first and mirror however existing tests drive it (if driving it requires a full RepoStore fixture that no existing test builds, test the preservation seam directly instead: whatever internal merge produces the new array must carry `isMain` workspaces through like orphans — name the test `testReloadPreservesMainWorkspace` and arrange at the lowest level the code allows; explain the choice in your report).

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter MainWorkspaceTests 2>&1 | tail -10`
Expected: BUILD FAILURE — `value of type 'WorkspaceStore' has no member 'mainWorkspace'`.

- [ ] **Step 4: Implement**

1. `Workspace.swift`: add `var isMain: Bool` with a doc comment ("The reserved main-branch workspace — permanent, excluded from feature machinery; see WorkspaceStore.mainWorkspace"), add `isMain: Bool = false` to the memberwise init (LAST parameter, so existing call sites compile unchanged).
2. `WorkspaceStore.swift`, next to `registerFeature`:

```swift
    /// Find-or-create the reserved main-branch workspace. Deterministic
    /// id (same trick registerFeature uses) so repeated activations and
    /// relaunches converge on one workspace; linked repos refresh on
    /// every call because the project's repo set can change.
    func mainWorkspace(
        name: String,
        workingDirectory: String,
        linkedRepoIDs: [String]
    ) -> Workspace {
        if let index = workspaces.firstIndex(where: { $0.isMain }) {
            workspaces[index].name = name
            workspaces[index].linkedRepoIDs = linkedRepoIDs
            workspaces[index].workingDirectory = workingDirectory
            return workspaces[index]
        }
        let workspace = Workspace(
            id: Self.deterministicID(for: "reserved-main-workspace"),
            name: name,
            symbol: "arrow.triangle.branch",
            workingDirectory: workingDirectory,
            linkedRepoIDs: linkedRepoIDs,
            isMain: true
        )
        workspaces.append(workspace)
        return workspace
    }
```

(Reuse the exact deterministic-UUID helper `registerFeature` uses — read it; if it's inline there, extract `private static func deterministicID(for seed: String) -> UUID` and use it from both. If `Workspace.tint` is non-optional in the memberwise init order, match the real parameter order.)

3. `WorkspaceStore.remove(_:)`: first line `guard !workspace.isMain else { return }` with a one-line comment.
4. `reloadFeatures(in:repoStore:)`: wherever orphans are preserved (explorer: line ~159, "orphans preserved"), preserve `isMain` workspaces the same way (they have non-empty `linkedRepoIDs`, so the orphan test won't catch them — add `|| $0.isMain` to whatever predicate keeps orphans, and make sure the final ordering keeps main FIRST or leaves it wherever it was; do not let it be treated as a stale feature and dropped).
5. `persistFeatureOrder()`: exclude `isMain` from what gets recorded (read the body; add a `!$0.isMain` filter).
6. `WorkspaceSidebar.swift`: `adHocWorkspaces` (~line 644) gains `&& !$0.isMain` (or `!workspace.isMain` in its filter) so the retired ad-hoc partition and its reorder splice never touch it; `closeFeature(_:)` (~line 935) gains `guard !workspace.isMain else { return }` (belt-and-braces — no UI offers it).

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter MainWorkspaceTests 2>&1 | tail -5`
Expected: `Test Suite 'MainWorkspaceTests' passed` — 4 tests.

- [ ] **Step 6: Full suite, commit**

Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1` → 0 failures.

```bash
git add Sources/Dreamux/Models/Workspace.swift Sources/Dreamux/Models/WorkspaceStore.swift Sources/Dreamux/Views/WorkspaceSidebar.swift Tests/DreamuxTests/MainWorkspaceTests.swift
git commit -m "Reserved main workspace: find-or-create, reload-proof, unremovable

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: File tree resolves main per-repo

**Files:**
- Modify: `Sources/Dreamux/Models/FileTreeStore.swift:18-36` (`roots`)
- Test: `Tests/DreamuxTests/FileTreeStoreTests.swift` (extend)

**Interfaces:**
- Consumes: `Workspace.isMain` (Task 1), existing `Repository.defaultBranch`.
- Produces: main workspaces get file-tree roots at `repos/<repo>/<repo.defaultBranch>` regardless of the workspace's display name.

- [ ] **Step 1: Write the failing test**

Read `FileTreeStoreTests.swift`'s fixture arrangement (it builds real directories), then add:

```swift
    /// A main workspace's roots resolve each repo's OWN default branch
    /// folder — repos in one project can name theirs differently, and
    /// the workspace's display name is just the first repo's.
    func testMainWorkspaceRootsUsePerRepoDefaultBranch() throws {
        // fixture: repo "web" with defaultBranch "main" and a main/ dir;
        // repo "api" with defaultBranch "master" and a master/ dir
        // (mirror the file's existing repo-fixture helpers)
        let workspace = Workspace(
            name: "main", workingDirectory: "/tmp/x",
            linkedRepoIDs: ["web", "api"], isMain: true)
        let roots = store.roots(for: workspace, repositories: [webRepo, apiRepo])
        XCTAssertEqual(roots.count, 2)
        XCTAssertTrue(roots[0].url.path.hasSuffix("web/main"))
        XCTAssertTrue(roots[1].url.path.hasSuffix("api/master"))
    }
```

(Adapt the `Workspace` init argument order to the real one from Task 1; construct repos however the file's existing tests do.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FileTreeStoreTests 2>&1 | tail -10`
Expected: the new test FAILS (roots empty or wrong paths — `api/main` doesn't exist).

- [ ] **Step 3: Implement**

In `roots(for:repositories:)`, replace the worktree line:

```swift
            // Main workspaces browse each repo's own default branch —
            // display name aside, "main" here can be "master" there.
            let branchFolder = workspace.isMain ? repo.defaultBranch : workspace.name
            let worktree = repo.rootURL.appendingPathComponent(branchFolder, isDirectory: true)
```

- [ ] **Step 4: Tests green, full suite, commit**

Run: `swift test --filter FileTreeStoreTests 2>&1 | tail -5` → passed.
Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1` → 0 failures.

```bash
git add Sources/Dreamux/Models/FileTreeStore.swift Tests/DreamuxTests/FileTreeStoreTests.swift
git commit -m "File tree resolves a main workspace per repo default branch

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: The pinned row + activation flow

**Files:**
- Modify: `Sources/Dreamux/Views/PlansSpecsSection.swift` (pinned row above the collapsible content + 3 new parameters)
- Modify: `Sources/Dreamux/Views/WorkspaceSidebar.swift` (wire parameters; `openMainWorkspace()`; `@State mainWorktreeIssue: String?`)

**Interfaces:**
- Consumes: `WorkspaceStore.mainWorkspace(name:workingDirectory:linkedRepoIDs:)` (Task 1), `GitOperations.worktreeURL/addWorktree` (existing), `WorkspaceRunControls` via the existing `makeRunControls` closure, `store.activeID`/`sidebarMode` (existing sidebar state).
- Produces: the shipped row.

- [ ] **Step 1: PlansSpecsSection — parameters and row**

Add three parameters (alongside the existing closures; update the single construction site in the same commit):

```swift
    /// The pinned main row: is the reserved main workspace currently
    /// the active one (selection styling)?
    let mainWorkspaceActive: Bool
    /// Non-nil when the last activation failed to materialize a
    /// default-branch worktree — rendered as a warning on the row.
    let mainWorktreeIssue: String?
    /// Activate (and lazily provision) the main workspace.
    let onOpenMain: () -> Void
```

Render the row between the section header and the `layout.plansExpanded` conditional (permanent — visible even collapsed). Reuse the section's row-chrome conventions (read a plan row first; match paddings/hover):

```swift
    /// The permanent main-branch row — a place, not a plan: no status
    /// machinery, no close/merge, always present. Clicking activates
    /// the reserved main workspace (worktrees materialize on demand).
    @ViewBuilder
    private var mainRow: some View {
        let repos = repoNamesForMainSubtitle
        Button {
            onOpenMain()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(mainWorktreeIssue == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mainBranchDisplayName)
                        .font(.callout.weight(mainWorkspaceActive ? .semibold : .medium))
                        .foregroundStyle(.primary)
                    if repos.count > 1 {
                        Text(repos.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let workspace = mainWorkspaceIfLive {
                    makeRunControls(workspace)
                        .opacity(mainRowHovered || runnersLive(for: workspace) ? 1 : 0)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(mainWorkspaceActive ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { mainRowHovered = $0 }
        .help(mainWorktreeIssue ?? "Work on \(mainBranchDisplayName) — terminal, files, and services on the default branch")
    }
```

The full parameter set is exactly these six (no more): the three above plus `let mainBranchDisplayName: String`, `let mainRepoNames: [String]` (plain data, computed in WorkspaceSidebar), and `let mainWorkspace: () -> Workspace?` (live accessor — WorkspaceSidebar passes `{ store.workspaces.first(where: \.isMain) }`). In the row code, `mainBranchDisplayName` replaces `mainBranchDisplayName`, `repoNamesForMainSubtitle` becomes `mainRepoNames`, and `mainWorkspaceIfLive` becomes `mainWorkspace()`. Add `@State private var mainRowHovered = false` and a `runnersLive(for:)` helper mirroring how feature rows decide `isRunning` (`!runners.runningRunners(onBranch: workspace.name).isEmpty`).

- [ ] **Step 2: WorkspaceSidebar — wiring + activation**

Add `@State private var mainWorktreeIssue: String?`. Pass the new arguments at the `PlansSpecsSection(` construction site (display name = `repoStore.repositories.first?.defaultBranch ?? "main"`, subtitle repos = `repoStore.repositories.map(\.name)`, `mainWorkspaceActive: store.workspaces.first(where: { $0.isMain })?.id == store.activeID && sidebarModeIsWorkspace` — adapt to how `isWorkspaceActive` is computed in this file). Add:

```swift
    /// Activate the reserved main workspace, materializing any missing
    /// default-branch worktrees. Failures land on the row (tooltip +
    /// warning tint), never in a modal — the workspace still activates
    /// so the terminal (project root) keeps working.
    private func openMainWorkspace() {
        let workspace = store.mainWorkspace(
            name: repoStore.repositories.first?.defaultBranch ?? "main",
            workingDirectory: repoStore.project.rootPath.path,
            linkedRepoIDs: repoStore.repositories.map(\.name))
        sidebarMode = .workspace
        store.activate(workspace.id)
        mainWorktreeIssue = nil
        Task { @MainActor in
            var issues: [String] = []
            for repo in repoStore.repositories {
                let existing = await GitOperations.worktreeURL(
                    forBranch: repo.defaultBranch, in: repo.rootURL)
                guard existing == nil else { continue }
                do {
                    try await GitOperations.addWorktree(
                        in: repo.rootURL, branch: repo.defaultBranch)
                } catch {
                    issues.append("\(repo.name): \(error.localizedDescription)")
                }
            }
            if !issues.isEmpty {
                mainWorktreeIssue = "Couldn't check out "
                    + issues.joined(separator: "; ")
            }
        }
    }
```

Wire `onOpenMain: { openMainWorkspace() }`.

- [ ] **Step 3: Build + full suite**

Run: `swift build 2>&1 | grep "error:" | head; echo BUILD-DONE` → no errors.
Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1` → 0 failures.

- [ ] **Step 4: Commit**

```bash
git add Sources/Dreamux/Views/PlansSpecsSection.swift Sources/Dreamux/Views/WorkspaceSidebar.swift
git commit -m "Pinned main row activates the default branch as a real workspace

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Verification + merge gate

**Files:** none (verification + git only)

- [ ] **Step 1: Build + relaunch from the worktree**

```bash
./Scripts/make-app.sh
PID=$(pgrep -x Dreamux); if [ -n "$PID" ]; then kill -TERM "$PID"; while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done; fi
open ./Dreamux.app --args -ApplePersistenceIgnoreState YES
sleep 4
```

- [ ] **Step 2: Live verification**

- The main row sits above the plans list, visible even with the section collapsed; branch glyph + default-branch name; repos subtitle only in multi-repo projects.
- Clicking it: terminal opens at the project root; the git chip shows the default branch's HEAD; the file tree shows each repo's default-branch worktree (materialized on first click for repos that lacked one — verify with `git -C <project>/repos/<repo> worktree list`); the play capsule scopes to main.
- The row has no Close/Merge anywhere; plan rows and features behave exactly as before; switching to a feature and back to main keeps both selections working; relaunching the app and clicking main again converges on the same workspace (no duplicates in ⌘1-9 ordering).
- A commit made on main elsewhere shows in the chip's commit trail (group 3 machinery unchanged).
- Screenshot the row (idle + selected) if capture is available.

- [ ] **Step 3: Present results to the user and wait for merge approval.** Do not merge without it.

- [ ] **Step 4: Merge and push (after approval)**

```bash
cd /Users/olliejarvis/Development/clayspace
git status --short && git log --oneline -1
git merge --ff-only pinned-main-row || git merge --no-edit pinned-main-row
swift test 2>&1 | grep -E "Executed .* tests" | tail -1
git push origin main
git worktree remove .claude/worktrees/pinned-main-row
git branch -d pinned-main-row
./Scripts/make-app.sh
PID=$(pgrep -x Dreamux); if [ -n "$PID" ]; then kill -TERM "$PID"; while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done; fi
open /Users/olliejarvis/Development/clayspace/Dreamux.app
```

Expected: ff merge (re-verify SHAs — main may move from parallel sessions), suite green on main, push accepted, canonical app relaunched from main.
