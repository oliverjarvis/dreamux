# Auto-Commit per Task + Commit Trail + Diffs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every completed plan task becomes a commit (agent-made, app-backstopped, settings-gated); the header's git chip opens a commit-trail popover; commits and task rows open a read-only Monaco side-by-side diff viewer tab.

**Architecture:** Three layers. (1) Git plumbing: `CommitInfo`/`commitLog`/`changedFiles`/`fileContent` on `GitOperations`. (2) Auto-commit: a prompt bullet (gated by a new Workflow settings toggle) instructs the agent to commit per task; `PlanQueueController.tick()` grows per-task completion snapshots and fires an injected `onTaskCompleted` hook — wired (like its other closures) to commit leftover changes in the feature's worktrees. (3) Diff UI: a fourth tab-session kind (`DiffTabSession`, Monaco `createDiffEditor` via a new `__setDiff` boot function), opened from a new commit-trail popover on the git chip and from task rows' "View changes".

**Tech Stack:** Swift/SwiftPM, SwiftUI, WKWebView + vendored Monaco (already includes the diff editor), XCTest. No new dependencies.

## Global Constraints

- Platform floor `macOS(.v14)`; no new SwiftPM dependencies.
- Auto-commit messages: agent commits use the task's full heading text verbatim (e.g. `Task 2: Commit trail popover` — `PlanTask.title` already carries it); backstop commits append ` (auto)`; the plan-review checkpoint commit message is `Plan review checkpoint (auto)`.
- The Workflow toggle key is `workflowAutoCommitPerTask`, **default ON when the key is absent** (`@AppStorage` declared with `= true`; non-SwiftUI readers must use the `WorkflowSettings.autoCommitEnabled` helper, never a bare `UserDefaults.bool` which defaults false).
- Flipping the toggle mid-plan takes effect at the next task boundary (the coordinator reads it at prompt-build; the queue wiring reads it per event).
- The diff viewer is read-only (`readOnly: true`, `originalEditable: false`); it must never write to disk or offer a save path.
- Chip popover styling matches the services popover (`HeaderRunControls.swift`): 320pt width, `.callout`/`.caption` typography, hover-revealed row actions, monospaced numerics size 11.
- Tests: XCTest in `Tests/DreamuxTests/`, house style (`@MainActor` where the type is, doc comments explaining *why*, `TestSandbox` for repo fixtures — see `GitOperationsTests.swift` for the git-fixture pattern; reuse its helpers rather than inventing new ones).
- Git hygiene: stage only named files (repo tracks `Scripts/` with a capital S); commit messages are plain sentences ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; full `swift test` green before each task's final commit.
- Delivery branch `auto-commit-diffs`; merge only after user approval (Task 7).

**Existing code this plan builds on (verified):**
- `Sources/Dreamux/Shell/GitOperations.swift` — `runGit(_:in:onLine:)` (non-interactive flags), `commitAll(message:in:)` (add -A + commit, throws), `hasUncommittedChanges(in:)` (status --porcelain), `worktreeURL(forBranch:in:)`, `GitHeadStatus`.
- `Sources/Dreamux/Models/PlanQueueController.swift` — `tick()` is a pure function of injected probes (`statusForPlan`, `featureNameForPlan`, `isFeatureQuiescent`), polled every 3s, constructed per project; closures wired at the construction site (see the comment near line 17 for where — ContentView / project scope).
- `Sources/Dreamux/Models/PlanDoc.swift` — `PlanTask` (`title` = full `Task N: …` heading text, `steps: [PlanStep]` with `checked`, document order, `line`); `PlanDoc.tasks`.
- `Sources/Dreamux/Shell/PlanRunCoordinator.swift` — builds `PlanPrompts.runPlan/resumePlan(planRelativePath:docsLinkName:)`, sends via injectable `sendPrompt`; already calls `MCPInstaller.installIfNeeded` pre-tab.
- `Sources/Dreamux/Shell/PlanPrompts.swift` — `runPlan`/`resumePlan` string builders (each currently has a contract bullet list including the dreamux-signals bullet); `PlanPromptsTests` pins their content.
- `Sources/Dreamux/Views/SettingsView.swift` — `AppearanceSettings` enum of `@AppStorage` key strings; grouped `Form` with two sections.
- Monaco: `Sources/Dreamux/Resources/Monaco/editor-boot.js` boots `monaco.editor.create` into `#container`, bridge = `window.webkit.messageHandlers.bridge.postMessage`; Swift-facing JS globals `__setContents/__getValue/__revealLine`; the vendored `vs/editor/editor.main.js` includes `monaco.editor.createDiffEditor`. `MonacoSchemeHandler.scheme` serves `app-monaco://app/index.html`.
- Tabs: `WorkspaceSession` holds three maps (`tabSessions`/`webTabSessions`/`fileTabSessions`), park-before-create pattern (`nextTabFileURL` etc.) consumed in `handleDidCreateTab`; `TabContentView` (Views/WorkspaceTerminalContainer.swift:77-94) dispatches by probing the maps in order.
- `Sources/Dreamux/Views/PlansSpecsSection.swift` — `taskRow(_:plan:isCurrent:indent:)` with a context menu ("Course correct…"); the section receives `featureName: (PlanDoc) -> String` and `workspaceForFeature: (String) -> Workspace?` closures.
- `Sources/Dreamux/Views/ContentView.swift` — git chip HStack inside `contextHeaderRow` (after `HeaderRunControls`); `resolveGitStatus()` already computes the active worktree URL before summarizing; `gitStatus` is `@State`, polled every 5s.

---

### Task 1: Git plumbing — commit log and file-level diff content

**Files:**
- Modify: `Sources/Dreamux/Shell/GitOperations.swift` (append after `headStatus`)
- Test: `Tests/DreamuxTests/GitCommitLogTests.swift`

**Interfaces:**
- Consumes: existing `runGit`, `TestSandbox` + the fixture-repo helpers used by `GitOperationsTests.swift` (read that file first; reuse its repo-creation helpers).
- Produces (later tasks rely on these exact names):
  - `struct CommitInfo: Equatable, Sendable, Identifiable { let sha: String; let shortSHA: String; let subject: String; let authorDate: Date?; let insertions: Int; let deletions: Int; var id: String { sha } }`
  - `GitOperations.commitLog(in: URL, baseBranch: String?, limit: Int = 50) async -> [CommitInfo]` — newest first; `baseBranch` non-nil → range `<baseBranch>..HEAD` (falling back to plain `HEAD` history when the range is empty or the base is unknown); nil → plain `HEAD` history.
  - `GitOperations.changedFiles(from: String?, to: String?, in: URL) async -> [(status: String, path: String)]` — `git diff --name-status <from> <to>`; `to == nil` means the working tree (`git diff --name-status <from>`); renames reported with status prefix "R" and the NEW path.
  - `GitOperations.fileContent(at path: String, revision: String?, in: URL) async -> String?` — `revision` non-nil → `git show <revision>:<path>`; nil → read the worktree file from disk. Returns nil for missing files or binary content (NUL byte check).
  - `GitOperations.rootCommitSHA(in: URL) async -> String?` — `git rev-list --max-parents=0 -n1 HEAD`, first line trimmed; the popover needs it because the root commit has no `^` parent to diff against.

- [ ] **Step 1: Create the working branch**

```bash
cd /Users/olliejarvis/Development/clayspace
git worktree add .claude/worktrees/auto-commit-diffs -b auto-commit-diffs
cd .claude/worktrees/auto-commit-diffs
```

- [ ] **Step 2: Write the failing tests**

Read `Tests/DreamuxTests/GitOperationsTests.swift` first and reuse its fixture helpers (sandbox + repo init + commit helpers). Create `Tests/DreamuxTests/GitCommitLogTests.swift` with this coverage (adapt arrangement to the existing helpers; the assertions below are the contract):

```swift
import XCTest
@testable import Dreamux

/// The commit-trail popover and task diffs are built on these three
/// primitives; each test drives real git in a sandbox repo because
/// parsing (--numstat tabs, binary "-" lines, rename statuses) is
/// exactly where hand-rolled git plumbing goes wrong.
final class GitCommitLogTests: XCTestCase {
    // ... sandbox/repo setup mirroring GitOperationsTests ...

    /// Two commits with known content: newest first, subjects intact,
    /// per-commit insertion/deletion totals correct, ISO author dates
    /// parsed. Binary changes ("-" numstat lines) must not poison the
    /// totals.
    func testCommitLogParsesSubjectsStatsAndDates() async throws {
        // commit 1: create a.txt with 2 lines ("one\ntwo")
        // commit 2: modify a.txt (+1 line), add b.bin (binary: Data([0,1,2]))
        let log = await GitOperations.commitLog(in: repoURL, baseBranch: nil)
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log[0].insertions, 1, "binary '-' lines are skipped")
        XCTAssertEqual(log[0].deletions, 0)
        XCTAssertEqual(log[1].insertions, 2)
        XCTAssertNotNil(log[0].authorDate)
        XCTAssertEqual(log[0].shortSHA.count, 7)
        XCTAssertTrue(log[0].sha.hasPrefix(log[0].shortSHA))
    }

    /// baseBranch scopes the log to branch-only commits; an empty
    /// range (HEAD == base) falls back to recent HEAD history rather
    /// than returning nothing — the chip on main still shows commits.
    func testCommitLogBaseBranchRangeAndFallback() async throws {
        // main: 1 commit; branch "feat": +2 commits
        let branchOnly = await GitOperations.commitLog(in: featWorktree, baseBranch: "main")
        XCTAssertEqual(branchOnly.count, 2)
        let onMain = await GitOperations.commitLog(in: repoURL, baseBranch: "main")
        XCTAssertEqual(onMain.count, 1, "empty range falls back to HEAD history")
    }

    /// name-status across a range, and against the working tree when
    /// `to` is nil — the popover's "Uncommitted changes" row.
    func testChangedFilesRangeAndWorktree() async throws {
        // range A..B: added b.txt (A), modified a.txt (M)
        let range = await GitOperations.changedFiles(from: shaA, to: shaB, in: repoURL)
        XCTAssertTrue(range.contains { $0.status == "A" && $0.path == "b.txt" })
        XCTAssertTrue(range.contains { $0.status == "M" && $0.path == "a.txt" })
        // dirty worktree: modify a.txt without committing
        let dirty = await GitOperations.changedFiles(from: "HEAD", to: nil, in: repoURL)
        XCTAssertEqual(dirty.map(\.path), ["a.txt"])
    }

    /// git-show content per revision; worktree content when revision
    /// nil; nil for a path missing at that revision and for binary.
    func testFileContentPerRevisionWorktreeMissingAndBinary() async throws {
        let old = await GitOperations.fileContent(at: "a.txt", revision: shaA, in: repoURL)
        XCTAssertEqual(old, "one\ntwo\n")
        let live = await GitOperations.fileContent(at: "a.txt", revision: nil, in: repoURL)
        XCTAssertEqual(live, "one\ntwo\nthree\nlocal-edit\n")
        let missing = await GitOperations.fileContent(at: "b.txt", revision: shaA, in: repoURL)
        XCTAssertNil(missing, "b.txt does not exist at shaA")
        let binary = await GitOperations.fileContent(at: "b.bin", revision: nil, in: repoURL)
        XCTAssertNil(binary, "NUL bytes → treat as binary, no diff text")
    }

    /// The popover diffs the root commit against the empty tree — it
    /// needs to know which commit IS the root.
    func testRootCommitSHA() async throws {
        let root = await GitOperations.rootCommitSHA(in: repoURL)
        XCTAssertEqual(root, shaA, "first commit in the fixture repo")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter GitCommitLogTests 2>&1 | tail -10`
Expected: BUILD FAILURE — `type 'GitOperations' has no member 'commitLog'`.

- [ ] **Step 4: Implement**

Append to `Sources/Dreamux/Shell/GitOperations.swift` (after `headStatus`, matching its style):

```swift
/// One commit in a worktree's trail — the commit-trail popover's row
/// model and the task-diff resolver's input.
struct CommitInfo: Equatable, Sendable, Identifiable {
    let sha: String
    let shortSHA: String
    let subject: String
    let authorDate: Date?
    let insertions: Int
    let deletions: Int
    var id: String { sha }
}

extension GitOperations {
    /// Commits on this worktree, newest first, with per-commit diff
    /// totals. `baseBranch` scopes to `<base>..HEAD` (the branch's own
    /// commits); when that range is empty or the base doesn't resolve
    /// (we're ON the default branch), fall back to plain HEAD history
    /// so the chip is never uselessly blank.
    ///
    /// Format: one `%H<TAB>%h<TAB>%s<TAB>%aI` line per commit followed
    /// by its --numstat lines (`ins<TAB>del<TAB>path`, "-" for binary)
    /// and a blank separator. Subjects can contain anything except \n,
    /// so the header line is parsed by splitting on TAB with a max of
    /// 4 fields.
    static func commitLog(
        in worktreeURL: URL,
        baseBranch: String?,
        limit: Int = 50
    ) async -> [CommitInfo] {
        let format = "--format=%H%x09%h%x09%s%x09%aI"
        var output: String?
        if let baseBranch {
            output = try? await runGit(
                ["log", format, "--numstat", "-n", String(limit), "\(baseBranch)..HEAD"],
                in: worktreeURL)
        }
        if output == nil || output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            output = try? await runGit(
                ["log", format, "--numstat", "-n", String(limit), "HEAD"],
                in: worktreeURL)
        }
        guard let output else { return [] }
        return parseCommitLog(output)
    }

    /// Split out for direct unit testing of the parsing edge cases
    /// (binary "-" numstat lines, tabs in nothing, blank separators).
    static func parseCommitLog(_ output: String) -> [CommitInfo] {
        var results: [CommitInfo] = []
        var current: (sha: String, short: String, subject: String, date: Date?)?
        var ins = 0, del = 0
        let isoParser = ISO8601DateFormatter()

        func flush() {
            if let c = current {
                results.append(CommitInfo(
                    sha: c.sha, shortSHA: c.short, subject: c.subject,
                    authorDate: c.date, insertions: ins, deletions: del))
            }
            current = nil; ins = 0; del = 0
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(separator: "\t", maxSplits: 3,
                                    omittingEmptySubsequences: false)
            if fields.count == 4, fields[0].count == 40,
               fields[0].allSatisfy({ $0.isHexDigit }) {
                flush()
                current = (
                    sha: String(fields[0]),
                    short: String(fields[1]),
                    subject: String(fields[2]),
                    date: isoParser.date(from: String(fields[3]))
                )
            } else if fields.count == 3 {
                // numstat: ins<TAB>del<TAB>path; "-" for binary sides.
                if let i = Int(fields[0]) { ins += i }
                if let d = Int(fields[1]) { del += d }
            }
        }
        flush()
        return results
    }

    /// `git diff --name-status` between two revisions, or against the
    /// working tree when `to` is nil. Rename lines (`R100<TAB>old<TAB>new`)
    /// surface the NEW path with the "R…" status.
    static func changedFiles(
        from: String?,
        to: String?,
        in worktreeURL: URL
    ) async -> [(status: String, path: String)] {
        var args = ["diff", "--name-status"]
        if let from { args.append(from) }
        if let to { args.append(to) }
        guard let output = try? await runGit(args, in: worktreeURL) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t",
                                   omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return nil }
            let status = String(parts[0])
            let path = String(parts.last!)  // rename: last field is new path
            return (status: status, path: path)
        }
    }

    /// The repo's root commit (no parents). The commit-trail popover
    /// diffs it against git's empty tree because `<root>^` doesn't
    /// exist.
    static func rootCommitSHA(in worktreeURL: URL) async -> String? {
        guard let output = try? await runGit(
            ["rev-list", "--max-parents=0", "-n1", "HEAD"], in: worktreeURL)
        else { return nil }
        let sha = output.split(separator: "\n").first.map(String.init) ?? ""
        return sha.isEmpty ? nil : sha
    }

    /// Text content of `path` at `revision` (`git show rev:path`), or
    /// from the working tree when revision is nil. Returns nil when
    /// the file doesn't exist there or looks binary (NUL byte) — the
    /// diff viewer shows an empty side instead of garbage.
    static func fileContent(
        at path: String,
        revision: String?,
        in worktreeURL: URL
    ) async -> String? {
        if let revision {
            guard let output = try? await runGit(
                ["show", "\(revision):\(path)"], in: worktreeURL)
            else { return nil }
            return output.contains("\0") ? nil : output
        }
        let url = worktreeURL.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.contains(0) { return nil }
        return String(data: data, encoding: .utf8)
    }
}
```

Note: if `runGit` strips or normalizes trailing newlines, adjust `testFileContentPerRevisionWorktreeMissingAndBinary`'s expected strings to match reality (read `runGit` first) — the contract that matters is content fidelity modulo the runner's documented trailing-newline behavior; document whichever holds in the test.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter GitCommitLogTests 2>&1 | tail -5`
Expected: `Test Suite 'GitCommitLogTests' passed` — 4 tests.

- [ ] **Step 6: Full suite, then commit**

Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1` → 0 failures.

```bash
git add Sources/Dreamux/Shell/GitOperations.swift Tests/DreamuxTests/GitCommitLogTests.swift
git commit -m "Commit log, changed files, and revision content plumbing

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Workflow settings toggle + agent prompt instruction

**Files:**
- Modify: `Sources/Dreamux/Views/SettingsView.swift` (new `WorkflowSettings` enum + new Form section)
- Modify: `Sources/Dreamux/Shell/PlanPrompts.swift` (`runPlan`, `resumePlan`)
- Modify: `Sources/Dreamux/Shell/PlanRunCoordinator.swift` (pass the flag)
- Test: `Tests/DreamuxTests/PlanPromptsTests.swift` (extend), `Tests/DreamuxTests/WorkflowSettingsTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `enum WorkflowSettings { static let autoCommitKey = "workflowAutoCommitPerTask"; static var autoCommitEnabled: Bool }` (in SettingsView.swift, sibling to `AppearanceSettings`)
  - `PlanPrompts.runPlan(planRelativePath:docsLinkName:autoCommit: Bool = true)` and same for `resumePlan` — Task 3's backstop and the queue wiring read `WorkflowSettings.autoCommitEnabled` too.

- [ ] **Step 1: Write the failing tests**

Extend `Tests/DreamuxTests/PlanPromptsTests.swift` (read it first; match its assertion style — it pins prompt content):

```swift
    /// The auto-commit contract bullet: present by default, absent
    /// when the Workflow toggle is off — the agent must not be told
    /// to commit when the user disabled per-task commits.
    func testRunPlanAutoCommitBulletFollowsFlag() {
        let on = PlanPrompts.runPlan(planRelativePath: "docs/p.md", docsLinkName: "docs")
        XCTAssertTrue(on.contains("commit the work"),
                      "default (true) includes the per-task commit bullet")
        XCTAssertTrue(on.contains("full heading text"))
        let off = PlanPrompts.runPlan(
            planRelativePath: "docs/p.md", docsLinkName: "docs", autoCommit: false)
        XCTAssertFalse(off.contains("full heading text"))
    }

    func testResumePlanAutoCommitBulletFollowsFlag() {
        let on = PlanPrompts.resumePlan(planRelativePath: "docs/p.md", docsLinkName: "docs")
        XCTAssertTrue(on.contains("full heading text"))
        let off = PlanPrompts.resumePlan(
            planRelativePath: "docs/p.md", docsLinkName: "docs", autoCommit: false)
        XCTAssertFalse(off.contains("full heading text"))
    }
```

Create `Tests/DreamuxTests/WorkflowSettingsTests.swift`:

```swift
import XCTest
@testable import Dreamux

/// The absent-key default is the trap: UserDefaults.bool defaults to
/// FALSE, but this feature ships default-ON. The helper is the single
/// sanctioned read path for non-SwiftUI code.
final class WorkflowSettingsTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: WorkflowSettings.autoCommitKey)
        super.tearDown()
    }

    func testAutoCommitDefaultsOnWhenKeyAbsent() {
        UserDefaults.standard.removeObject(forKey: WorkflowSettings.autoCommitKey)
        XCTAssertTrue(WorkflowSettings.autoCommitEnabled)
    }

    func testAutoCommitHonorsExplicitOff() {
        UserDefaults.standard.set(false, forKey: WorkflowSettings.autoCommitKey)
        XCTAssertFalse(WorkflowSettings.autoCommitEnabled)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "WorkflowSettingsTests|PlanPromptsTests" 2>&1 | tail -10`
Expected: BUILD FAILURE — `cannot find 'WorkflowSettings' in scope` (and missing `autoCommit:` label).

- [ ] **Step 3: Implement the settings side**

In `Sources/Dreamux/Views/SettingsView.swift`, below `AppearanceSettings`:

```swift
/// Workflow behavior knobs — how plan runs behave, as opposed to how
/// the window looks. Same raw-key pattern as AppearanceSettings.
enum WorkflowSettings {
    static let autoCommitKey = "workflowAutoCommitPerTask"

    /// Default-ON when unset. UserDefaults.bool(forKey:) returns false
    /// for absent keys, which would silently ship the feature off —
    /// every non-SwiftUI read goes through here.
    static var autoCommitEnabled: Bool {
        UserDefaults.standard.object(forKey: autoCommitKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: autoCommitKey)
    }
}
```

In the `SettingsView` struct add `@AppStorage(WorkflowSettings.autoCommitKey) private var autoCommitPerTask = true`, and append a new section to the `Form` (after the colors section):

```swift
            Section {
                Toggle("Commit after each task", isOn: $autoCommitPerTask)
                Text("Plan agents commit each finished task; the app commits any leftovers when it sees a task complete. Off means plans only commit when the agent chooses to. Takes effect from the next task boundary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Workflow")
            }
```

- [ ] **Step 4: Implement the prompt side**

In `Sources/Dreamux/Shell/PlanPrompts.swift`, change both signatures to `runPlan(planRelativePath: String, docsLinkName: String, autoCommit: Bool = true)` / `resumePlan(planRelativePath: String, docsLinkName: String, autoCommit: Bool = true)`. In each, make the contract bullet list append this bullet when `autoCommit` is true (build the bullet as a `let autoCommitBullet = autoCommit ? "\n- After finishing each task — all its checkboxes ticked — commit the work in every repo subfolder you touched: `git add -A && git commit` with the commit message set to the task's full heading text (e.g. \"Task 2: Wire the store\"). One commit per task per repo." : ""` and interpolate it where the bullets sit — read the current string layout and splice consistently with the existing bullets' backslash-continuation style).

- [ ] **Step 5: Pass the flag from the coordinator**

In `Sources/Dreamux/Shell/PlanRunCoordinator.swift`, where the prompt is built:

```swift
        let autoCommit = WorkflowSettings.autoCommitEnabled
        let prompt = isResume
            ? PlanPrompts.resumePlan(
                planRelativePath: pathInFeature, docsLinkName: docsLink,
                autoCommit: autoCommit)
            : PlanPrompts.runPlan(
                planRelativePath: pathInFeature, docsLinkName: docsLink,
                autoCommit: autoCommit)
```

- [ ] **Step 6: Run tests, full suite, commit**

Run: `swift test --filter "WorkflowSettingsTests|PlanPromptsTests" 2>&1 | tail -5` → passed (existing PlanPromptsTests must stay green — if any pinned-content test breaks because of the new bullet, update it to expect the default-on bullet and say so in the report).
Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1` → 0 failures.

```bash
git add Sources/Dreamux/Views/SettingsView.swift Sources/Dreamux/Shell/PlanPrompts.swift Sources/Dreamux/Shell/PlanRunCoordinator.swift Tests/DreamuxTests/PlanPromptsTests.swift Tests/DreamuxTests/WorkflowSettingsTests.swift
git commit -m "Workflow setting: agents commit after each task (default on)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Queue backstop — task-completion events + leftover commits

**Files:**
- Modify: `Sources/Dreamux/Models/PlanQueueController.swift`
- Modify: the controller's construction/wiring site (find it: `grep -rn "PlanQueueController(" Sources/Dreamux --include="*.swift"` — wire the two new closures where `featureNameForPlan` etc. are wired)
- Test: `Tests/DreamuxTests/PlanQueueControllerTests.swift` (extend, matching its fake-driven style)

**Interfaces:**
- Consumes: `WorkflowSettings.autoCommitEnabled` (Task 2), `GitOperations.commitAll/hasUncommittedChanges/worktreeURL` (existing), `PlanTask` (existing).
- Produces (used by the wiring, same file set):
  - `PlanQueueController.completedTaskTitlesForPlan: ((String) -> [String]?)?` — injected probe: ordered titles of the plan's fully-checked tasks (nil = plan unreadable). The wiring implements it from `DocStore`'s parsed `PlanDoc.tasks` (`steps.allSatisfy(\.checked)`, skipping empty-title synthetic buckets and zero-step tasks).
  - `PlanQueueController.onTaskCompleted: ((_ planPath: String, _ taskTitle: String) -> Void)?` — fires once per newly-completed task while running.
  - `PlanQueueController.onPlanReachedReview: ((_ planPath: String) -> Void)?` — fires once on the `.running → .atGate` transition.

- [ ] **Step 1: Write the failing tests**

Read `Tests/DreamuxTests/PlanQueueControllerTests.swift` first — extend with its existing fake-probe arrangement (the tests drive `tick()` directly):

```swift
    /// The backstop's trigger: a task flipping to fully-checked between
    /// ticks fires onTaskCompleted exactly once, with the task's title.
    func testTaskCompletionFiresOncePerNewlyCompletedTask() {
        // arrange: controller running plan "p.md"; completedTaskTitlesForPlan
        // fake returns a mutable array
        var completed: [String] = []
        var events: [(String, String)] = []
        controller.completedTaskTitlesForPlan = { _ in completed }
        controller.onTaskCompleted = { events.append(($0, $1)) }
        // ... put controller into .running on "p.md" per existing helpers ...

        controller.tick()                       // baseline snapshot, no events
        XCTAssertTrue(events.isEmpty)

        completed = ["Task 1: Foundations"]
        controller.tick()
        XCTAssertEqual(events.map(\.1), ["Task 1: Foundations"])

        controller.tick()                       // unchanged → no re-fire
        XCTAssertEqual(events.count, 1)

        completed = ["Task 1: Foundations", "Task 2: Wiring"]
        controller.tick()
        XCTAssertEqual(events.map(\.1), ["Task 1: Foundations", "Task 2: Wiring"])
    }

    /// Resume safety: the FIRST observation of a plan seeds the
    /// snapshot silently — tasks completed before the app launched
    /// (or before the queue started) must not trigger a storm of
    /// stale backstop commits.
    func testFirstObservationSeedsWithoutFiring() {
        var events: [(String, String)] = []
        controller.completedTaskTitlesForPlan = { _ in ["Task 1: Done long ago"] }
        controller.onTaskCompleted = { events.append(($0, $1)) }
        // ... running on "p.md" ...
        controller.tick()
        XCTAssertTrue(events.isEmpty, "pre-existing completions are history, not events")
    }

    /// The review checkpoint: the .running → .atGate transition fires
    /// onPlanReachedReview exactly once.
    func testReviewTransitionFiresPlanReachedReview() {
        var reviews: [String] = []
        controller.onPlanReachedReview = { reviews.append($0) }
        // ... running on "p.md", then statusForPlan fake flips to .awaitingReview ...
        controller.tick()
        XCTAssertEqual(reviews, ["p.md"])
        controller.tick()                        // already atGate → no re-fire
        XCTAssertEqual(reviews.count, 1)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PlanQueueControllerTests 2>&1 | tail -10`
Expected: BUILD FAILURE — no member `completedTaskTitlesForPlan`.

- [ ] **Step 3: Implement in PlanQueueController**

Add alongside the existing injected probes:

```swift
    /// Ordered titles of the plan's fully-checked tasks — injected so
    /// tick() stays a pure function of probes. nil = plan unreadable.
    var completedTaskTitlesForPlan: ((String) -> [String]?)?
    /// Fires once per task that transitions to fully-checked while the
    /// queue is running the plan — the auto-commit backstop's trigger.
    var onTaskCompleted: ((_ planPath: String, _ taskTitle: String) -> Void)?
    /// Fires once when the running plan reaches review (.atGate) — the
    /// backstop's final leftover-commit checkpoint.
    var onPlanReachedReview: ((_ planPath: String) -> Void)?

    /// Last observed completed-task set per plan path. Seeded silently
    /// on first observation so pre-existing completions never fire
    /// stale events (relaunch/resume safety). In-memory only: a fresh
    /// launch re-seeds, which is exactly the conservative behavior we
    /// want for the backstop.
    private var observedCompletedTasks: [String: Set<String>] = [:]
```

In `tick()`, after the `guard let status` and before the `switch`, add:

```swift
        if case .running = state {
            noteTaskCompletions(for: path)
        }
```

Add the private method:

```swift
    private func noteTaskCompletions(for path: String) {
        guard let titles = completedTaskTitlesForPlan?(path) else { return }
        let completed = Set(titles)
        guard let previous = observedCompletedTasks[path] else {
            observedCompletedTasks[path] = completed   // seed silently
            return
        }
        guard completed != previous else { return }
        // Preserve document order for multi-task flips in one tick.
        for title in titles where !previous.contains(title) {
            onTaskCompleted?(path, title)
        }
        observedCompletedTasks[path] = completed
    }
```

In the `case (.running, .awaitingReview):` branch, before `state = .atGate`, add one line: `noteTaskCompletions(for: path)` (catch the final task's flip in the same tick) and after `state = .atGate` add `onPlanReachedReview?(path)`.

- [ ] **Step 4: Wire the backstop at the construction site**

Find where the controller's other closures are wired (`grep -rn "featureNameForPlan" Sources/Dreamux --include="*.swift"` — the non-definition hit). At that site, using whatever store references are in scope (the same ones `featureNameForPlan` uses), wire:

```swift
        queue.completedTaskTitlesForPlan = { [weak docStore] path in
            guard let plan = docStore?.plans.first(where: {
                docStore?.relativePath(of: $0) == path
            }) else { return nil }
            return plan.tasks
                .filter { !$0.title.isEmpty && !$0.steps.isEmpty
                          && $0.steps.allSatisfy(\.checked) }
                .map(\.title)
        }
        queue.onTaskCompleted = { path, title in
            Self.backstopCommit(message: "\(title) (auto)", planPath: path)
        }
        queue.onPlanReachedReview = { path in
            Self.backstopCommit(message: "Plan review checkpoint (auto)", planPath: path)
        }
```

and add a static helper NEXT TO the wiring (adapt the store access to what's actually in scope there — the closures above show the intent; the implementer adapts names after reading the site):

```swift
    /// The auto-commit backstop: commit whatever the agent left
    /// uncommitted in each of the feature's repo worktrees. Fire and
    /// forget — failures are logged, never block the queue.
    static func backstopCommit(message: String, planPath: String, /* stores in scope */) {
        guard WorkflowSettings.autoCommitEnabled else { return }
        Task { @MainActor in
            // feature name via the same ledger lookup featureNameForPlan uses;
            // workspace via workspaceStore; repos via workspace.linkedRepoIDs;
            // worktree via GitOperations.worktreeURL(forBranch: feature, in: repo.rootURL)
            for worktree in resolvedWorktrees {
                guard await GitOperations.hasUncommittedChanges(in: worktree) else { continue }
                do { try await GitOperations.commitAll(message: message, in: worktree) }
                catch { NSLog("auto-commit backstop failed in %@: %@",
                              worktree.path, String(describing: error)) }
            }
        }
    }
```

(The exact store plumbing depends on the wiring site's scope — `featureNameForPlan`'s implementation directly above it is the template: same ledger record lookup, then `workspaceStore.workspaces.first { $0.name == feature }`, then that workspace's linked repos to `GitOperations.worktreeURL(forBranch:in:)`. If the wiring site lacks a store the lookup needs, thread it the same way the existing closures got theirs. Do NOT put git calls inside `tick()` itself — events out, async work in the wiring.)

- [ ] **Step 5: Run tests, full suite, commit**

Run: `swift test --filter PlanQueueControllerTests 2>&1 | tail -5` → all green (existing queue tests must not regress).
Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1` → 0 failures.

```bash
git add Sources/Dreamux/Models/PlanQueueController.swift Tests/DreamuxTests/PlanQueueControllerTests.swift <wiring-site file>
git commit -m "Queue backstop commits leftover changes at task and review boundaries

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Monaco diff viewer tab

**Files:**
- Modify: `Sources/Dreamux/Resources/Monaco/editor-boot.js` (add `__setDiff`)
- Create: `Sources/Dreamux/Models/DiffTabSession.swift`
- Modify: `Sources/Dreamux/Models/WorkspaceSession.swift` (fourth session map + `openDiffTab`)
- Modify: `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift` (dispatch + `DiffTabView`)
- Test: `Tests/DreamuxTests/DiffTabSessionTests.swift`

**Interfaces:**
- Consumes: `GitOperations.changedFiles/fileContent` (Task 1), `MonacoSchemeHandler` (existing), Bonsplit `createTab` + `handleDidCreateTab` park-before-create pattern (existing).
- Produces (Tasks 5–6 rely on):
  - `struct DiffRequest: Equatable { let worktreeURL: URL; let fromRevision: String; let toRevision: String?; let title: String }` — `toRevision == nil` means the working tree.
  - `@MainActor @Observable final class DiffTabSession` — `init(request: DiffRequest)`, `let request: DiffRequest`, `private(set) var files: [DiffFileEntry]`, `var selectedPath: String?`, `private(set) var isLoading: Bool`, `var webView: WKWebView` (lazy, same scheme handler + bridge pattern as FileEditorTabSession), `func selectFile(_ path: String)`.
  - `struct DiffFileEntry: Identifiable, Equatable { let status: String; let path: String; var id: String { path } }`
  - `WorkspaceSession.openDiffTab(_ request: DiffRequest)` — parks the request, creates the tab (icon `"plus.forwardslash.minus"`), associates a `DiffTabSession`; `diffTabSession(for: TabID) -> DiffTabSession?`.

- [ ] **Step 1: editor-boot.js — the diff mode**

Read `editor-boot.js` fully first. Add, alongside `__setContents` (inside the same scope where `editor` and language helpers live):

```javascript
// Read-only side-by-side diff. First call disposes the standard
// editor and replaces it with a diff editor in the same container;
// later calls just swap models. ext drives language inference the
// same way __setContents does.
let diffEditor = null;
window.__setDiff = function (originalText, modifiedText, ext, theme) {
  const language = languageForExt(ext);   // reuse the existing helper name — read the file; if __setContents infers language differently (e.g. inline), extract/reuse that exact logic
  if (!diffEditor) {
    if (window.editor) { window.editor.dispose(); window.editor = null; }
    diffEditor = monaco.editor.createDiffEditor(
      document.getElementById('container'), {
        automaticLayout: true,
        readOnly: true,
        originalEditable: false,
        renderSideBySide: true,
        minimap: { enabled: false },
        fontSize: 14,
      });
  }
  monaco.editor.setTheme(theme || 'vs');
  const original = monaco.editor.createModel(originalText ?? '', language);
  const modified = monaco.editor.createModel(modifiedText ?? '', language);
  const old = diffEditor.getModel();
  diffEditor.setModel({ original, modified });
  if (old) { old.original.dispose(); old.modified.dispose(); }
};
```

Adapt the language-inference call to however `__setContents` actually does it (read first — if it's inline, factor the existing logic into a shared function rather than duplicating it). Do not touch the standard-editor path otherwise; a file tab and a diff tab never share a webview.

- [ ] **Step 2: Write the failing session tests**

Create `Tests/DreamuxTests/DiffTabSessionTests.swift` (model logic only — no webview assertions; the webview push happens on the JS `ready` bridge message which tests don't exercise):

```swift
import XCTest
@testable import Dreamux

/// DiffTabSession's model layer: file-list loading from a real repo
/// and content-pair resolution per revision. The Monaco push itself is
/// visual (verified in Task 7); what must be right here is WHICH
/// content lands on each side for adds, edits, deletes, and the
/// worktree ("uncommitted") case.
@MainActor
final class DiffTabSessionTests: XCTestCase {
    // sandbox repo helpers as in GitCommitLogTests:
    // commit A: a.txt = "one\n"; commit B: a.txt = "one\ntwo\n", b.txt added,
    // then working tree: a.txt = "one\ntwo\nthree\n" uncommitted

    func testLoadsChangedFilesForRange() async throws {
        let session = DiffTabSession(request: DiffRequest(
            worktreeURL: repoURL, fromRevision: shaA, toRevision: shaB,
            title: "A → B"))
        await session.loadForTesting()
        XCTAssertEqual(Set(session.files.map(\.path)), ["a.txt", "b.txt"])
        XCTAssertEqual(session.selectedPath, session.files.first?.path,
                       "first file auto-selected")
        XCTAssertFalse(session.isLoading)
    }

    func testContentPairsPerStatus() async throws {
        let session = DiffTabSession(request: DiffRequest(
            worktreeURL: repoURL, fromRevision: shaA, toRevision: shaB,
            title: "A → B"))
        await session.loadForTesting()
        let edited = await session.contentPair(for: "a.txt")
        XCTAssertEqual(edited.original, "one\n")
        XCTAssertEqual(edited.modified, "one\ntwo\n")
        let added = await session.contentPair(for: "b.txt")
        XCTAssertNil(added.original, "added file has no original side")
        XCTAssertNotNil(added.modified)
    }

    func testWorktreeSideWhenToRevisionNil() async throws {
        let session = DiffTabSession(request: DiffRequest(
            worktreeURL: repoURL, fromRevision: "HEAD", toRevision: nil,
            title: "Uncommitted"))
        await session.loadForTesting()
        let pair = await session.contentPair(for: "a.txt")
        XCTAssertEqual(pair.modified, "one\ntwo\nthree\n",
                       "nil toRevision reads the live worktree file")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter DiffTabSessionTests 2>&1 | tail -10`
Expected: BUILD FAILURE — `cannot find 'DiffTabSession' in scope`.

- [ ] **Step 4: Implement DiffTabSession**

Create `Sources/Dreamux/Models/DiffTabSession.swift` (mirror `FileEditorTabSession`'s webview/bridge conventions — read it first):

```swift
import Foundation
import Observation
import WebKit

/// A revision range to diff inside one repo worktree. `toRevision`
/// nil means the working tree — the "Uncommitted changes" row.
struct DiffRequest: Equatable {
    let worktreeURL: URL
    let fromRevision: String
    let toRevision: String?
    let title: String
}

/// One changed file in the diff tab's left rail.
struct DiffFileEntry: Identifiable, Equatable {
    let status: String
    let path: String
    var id: String { path }
}

/// Read-only diff tab: a file list plus a Monaco diff editor. Owns its
/// webview the same way FileEditorTabSession does (lazy, retained by
/// the session so pane moves don't reload Monaco), but never writes —
/// there is no save path in or out.
@MainActor
@Observable
final class DiffTabSession {
    let request: DiffRequest
    private(set) var files: [DiffFileEntry] = []
    private(set) var isLoading = true
    var selectedPath: String?
    private var jsReady = false

    private var _webView: WKWebView?
    private static let schemeHandler = MonacoSchemeHandler()

    init(request: DiffRequest) {
        self.request = request
        Task { await load() }
    }

    var webView: WKWebView {
        if let _webView { return _webView }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(
            Self.schemeHandler, forURLScheme: MonacoSchemeHandler.scheme)
        config.userContentController.add(Bridge(owner: self), name: "bridge")
        let view = WKWebView(frame: .zero, configuration: config)
        view.load(URLRequest(url: URL(string: "app-monaco://app/index.html")!))
        _webView = view
        return view
    }

    /// Test seam: run the same load the initializer kicks off, awaitably.
    func loadForTesting() async { await load() }

    private func load() async {
        let changed = await GitOperations.changedFiles(
            from: request.fromRevision,
            to: request.toRevision,
            in: request.worktreeURL)
        files = changed.map { DiffFileEntry(status: $0.status, path: $0.path) }
        isLoading = false
        if selectedPath == nil, let first = files.first?.path {
            selectFile(first)
        }
    }

    /// Both sides of one file's diff. nil side = file absent there
    /// (added/deleted) or binary.
    func contentPair(for path: String) async -> (original: String?, modified: String?) {
        async let original = GitOperations.fileContent(
            at: path, revision: request.fromRevision, in: request.worktreeURL)
        async let modified = GitOperations.fileContent(
            at: path, revision: request.toRevision, in: request.worktreeURL)
        return (await original, await modified)
    }

    func selectFile(_ path: String) {
        selectedPath = path
        Task { await pushSelected() }
    }

    private func pushSelected() async {
        guard jsReady, let path = selectedPath else { return }
        let pair = await contentPair(for: path)
        let ext = (path as NSString).pathExtension
        pushDiff(original: pair.original ?? "", modified: pair.modified ?? "", ext: ext)
    }

    private func pushDiff(original: String, modified: String, ext: String) {
        guard let webView = _webView else { return }
        // Follow FileEditorTabSession's JS-string encoding helper
        // pattern for safe embedding (read how it encodes __setContents
        // arguments and reuse the same approach/helper).
        let js = "__setDiff(\(Self.jsString(original)), \(Self.jsString(modified)), \(Self.jsString(ext)), 'vs')"
        webView.evaluateJavaScript(js)
    }

    private static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(
            withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private final class Bridge: NSObject, WKScriptMessageHandler {
        weak var owner: DiffTabSession?
        init(owner: DiffTabSession) { self.owner = owner }
        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let dict = message.body as? [String: Any],
                  dict["type"] as? String == "ready" else { return }
            Task { @MainActor in
                guard let owner = self.owner else { return }
                owner.jsReady = true
                await owner.pushSelected()
            }
        }
    }
}
```

(If `FileEditorTabSession` already has an equivalent `jsString`-style encoder or theme resolution, reuse/mirror those exactly instead of the sketches above — consistency beats novelty. Same for how it retains its `Bridge`.)

- [ ] **Step 5: WorkspaceSession + dispatch**

In `Sources/Dreamux/Models/WorkspaceSession.swift`, following the existing three-map pattern exactly:
- Add `private var diffTabSessions: [TabID: DiffTabSession] = [:]` and `private var nextDiffRequest: DiffRequest?`.
- Add accessor `func diffTabSession(for id: TabID) -> DiffTabSession? { diffTabSessions[id] }`.
- Add, mirroring `openFileTab`'s shape (no dedup — every request is a fresh snapshot):

```swift
    /// Open a read-only diff tab for a revision range. No dedup: a
    /// diff is a snapshot of a question ("what changed here?"), and
    /// asking again deserves fresh content.
    func openDiffTab(_ request: DiffRequest) {
        nextDiffRequest = request
        controller.createTab(title: request.title, icon: "plus.forwardslash.minus")
        nextDiffRequest = nil
    }
```

- In `handleDidCreateTab`, add a branch BEFORE the web/terminal fallbacks (mirroring the `nextTabFileURL` branch):

```swift
        if let request = nextDiffRequest {
            nextDiffRequest = nil
            diffTabSessions[tab.id] = DiffTabSession(request: request)
            return
        }
```

- Check how tab teardown/close cleans the other three maps (grep `fileTabSessions` removal sites in the file) and clean `diffTabSessions` in the same places.

In `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift`:
- In `TabContentView`'s probe chain add, before the web-tab branch: `else if let diffTab = session.diffTabSession(for: tabId) { DiffTabView(session: diffTab) }`.
- Add the view (same file, near FileEditorView):

```swift
/// The diff tab: changed-file rail + Monaco side-by-side. Read-only by
/// construction — the session has no save path.
private struct DiffTabView: View {
    @Bindable var session: DiffTabSession

    var body: some View {
        HSplitView {
            List(session.files, selection: Binding(
                get: { session.selectedPath },
                set: { if let path = $0 { session.selectFile(path) } }
            )) { file in
                HStack(spacing: 6) {
                    Text(file.status.prefix(1))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor(file.status))
                        .frame(width: 14)
                    Text(file.path)
                        .font(.callout)
                        .lineLimit(1).truncationMode(.head)
                }
                .tag(file.path)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 340)

            FileEditorWebView(webView: session.webView)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if session.isLoading {
                ProgressView()
            } else if session.files.isEmpty {
                Text("No changes in this range")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status.first {
        case "A": return .green
        case "D": return .red
        case "R": return .orange
        default: return .secondary
        }
    }
}
```

(`FileEditorWebView` is the existing WKWebView representable in this file — reuse it. If it's fileprivate to another scope, hoist or duplicate per the file's conventions and note it.)

- [ ] **Step 6: Run tests, full suite, commit**

Run: `swift test --filter DiffTabSessionTests 2>&1 | tail -5` → 3 tests passed.
Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1` → 0 failures.

```bash
git add Sources/Dreamux/Resources/Monaco/editor-boot.js Sources/Dreamux/Models/DiffTabSession.swift Sources/Dreamux/Models/WorkspaceSession.swift Sources/Dreamux/Views/WorkspaceTerminalContainer.swift Tests/DreamuxTests/DiffTabSessionTests.swift
git commit -m "Read-only Monaco diff viewer as a fourth tab kind

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Commit-trail popover on the git chip

**Files:**
- Create: `Sources/Dreamux/Views/CommitTrailPopover.swift`
- Modify: `Sources/Dreamux/Views/ContentView.swift` (chip → Button + popover; stash the resolved worktree)
- Test: none new (view-only; the data layer is Task 1-tested; visuals in Task 7)

**Interfaces:**
- Consumes: `CommitInfo`, `GitOperations.commitLog/hasUncommittedChanges` (Task 1), `DiffRequest` + `WorkspaceSession.openDiffTab` (Task 4), `gitStatus`/`resolveGitStatus` (existing).
- Produces: `struct CommitTrailPopover: View` with init `(worktreeURL: URL, branch: String, defaultBranch: String?, openDiff: @escaping (DiffRequest) -> Void)`.

- [ ] **Step 1: Stash the worktree beside gitStatus**

In `ContentView`, add `@State private var gitWorktree: URL?`, `@State private var gitDefaultBranch: String?`, and `@State private var showCommitTrail = false`. Change `resolveGitStatus()` to return `(status: GitHeadStatus, worktree: URL, defaultBranch: String)?` — it already has both `worktree` and the chosen `repo` in hand right before calling `headStatus` (return `repo.defaultBranch`, NOT `repositories.first` — in a multi-repo project the chip's worktree belongs to whichever candidate repo the resolver picked). Destructure into the three states in the poll task.

- [ ] **Step 2: Chip becomes a button**

Wrap the existing chip HStack (branch/SHA/±) in a `Button { showCommitTrail = true } label: { <existing chip content unchanged> }` with `.buttonStyle(.plain)` and attach:

```swift
                .popover(isPresented: $showCommitTrail, arrowEdge: .bottom) {
                    if let worktree = gitWorktree, let git = gitStatus {
                        CommitTrailPopover(
                            worktreeURL: worktree,
                            branch: git.branch,
                            defaultBranch: gitDefaultBranch,
                            openDiff: { request in
                                showCommitTrail = false
                                openDiffTab(request)
                            })
                    }
                }
```

Add the ContentView helper (next to `openFile`):

```swift
    /// Route a diff request into the active workspace's pane, flipping
    /// to the terminal/tab view so the new tab is visible (same move
    /// as openFile).
    private func openDiffTab(_ request: DiffRequest) {
        guard let workspace = store.activeWorkspace else { return }
        sidebarMode = .workspace
        store.session(for: workspace).openDiffTab(request)
    }
```

The `.help` on the chip becomes "Commit trail of the active worktree".

- [ ] **Step 3: The popover view**

Create `Sources/Dreamux/Views/CommitTrailPopover.swift`:

```swift
import SwiftUI

/// The git chip's dropdown: this worktree's commits, newest first,
/// each opening a diff vs its parent. Styling matches the services
/// popover (HeaderRunControls) — 320pt, callout/caption, hover rows.
struct CommitTrailPopover: View {
    let worktreeURL: URL
    let branch: String
    let defaultBranch: String?
    let openDiff: (DiffRequest) -> Void

    @State private var commits: [CommitInfo] = []
    @State private var hasUncommitted = false
    @State private var loaded = false
    @State private var hoveredID: String?
    @State private var rootSHA: String?

    /// Git's canonical empty-tree object — the "parent" of a root
    /// commit for diffing purposes (`<root>^` does not exist).
    private static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if hasUncommitted {
                        uncommittedRow
                    }
                    ForEach(commits) { commit in
                        commitRow(commit)
                    }
                    if loaded && commits.isEmpty && !hasUncommitted {
                        Text("No commits yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 340)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(branch)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 12)
            if let base = defaultBranch, base != branch {
                Button {
                    openDiff(DiffRequest(
                        worktreeURL: worktreeURL,
                        fromRevision: base,
                        toRevision: "HEAD",
                        title: "\(branch) vs \(base)"))
                } label: {
                    Label("Diff vs \(base)", systemImage: "plus.forwardslash.minus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Everything this branch changes relative to \(base)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var uncommittedRow: some View {
        row(
            id: "uncommitted",
            title: "Uncommitted changes",
            titleStyle: AnyShapeStyle(Color.orange),
            subtitle: "working tree vs HEAD",
            badge: nil
        ) {
            openDiff(DiffRequest(
                worktreeURL: worktreeURL,
                fromRevision: "HEAD",
                toRevision: nil,
                title: "Uncommitted changes"))
        }
    }

    private func commitRow(_ commit: CommitInfo) -> some View {
        row(
            id: commit.sha,
            title: commit.subject,
            titleStyle: AnyShapeStyle(.primary),
            subtitle: subtitleFor(commit),
            badge: commit.subject.hasPrefix("Task ") ? "checkmark.circle" : nil
        ) {
            openDiff(DiffRequest(
                worktreeURL: worktreeURL,
                fromRevision: commit.sha == rootSHA ? Self.emptyTree : "\(commit.sha)^",
                toRevision: commit.sha,
                title: commit.shortSHA))
        }
        .contextMenu {
            Button("Copy SHA") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.sha, forType: .string)
            }
        }
    }

    private func subtitleFor(_ commit: CommitInfo) -> String {
        var parts = [commit.shortSHA]
        if commit.insertions > 0 || commit.deletions > 0 {
            parts.append("+\(commit.insertions) −\(commit.deletions)")
        }
        return parts.joined(separator: "  ")
    }

    private func row(
        id: String,
        title: String,
        titleStyle: AnyShapeStyle,
        subtitle: String,
        badge: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        if let badge {
                            Image(systemName: badge)
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                                .help("Task commit")
                        }
                        Text(title)
                            .font(.callout)
                            .foregroundStyle(titleStyle)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Text(subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if hoveredID == id {
                    Image(systemName: "plus.forwardslash.minus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .help("View diff")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hoveredID == id ? Color.primary.opacity(0.06) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredID = id }
            else if hoveredID == id { hoveredID = nil }
        }
    }

    private func load() async {
        hasUncommitted = await GitOperations.hasUncommittedChanges(in: worktreeURL)
        commits = await GitOperations.commitLog(
            in: worktreeURL, baseBranch: defaultBranch)
        rootSHA = await GitOperations.rootCommitSHA(in: worktreeURL)
        loaded = true
    }
}
```

- [ ] **Step 4: Build, full suite, commit**

Run: `swift build 2>&1 | grep "error:" | head; echo BUILD-DONE` → no errors.
Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1` → 0 failures.

```bash
git add Sources/Dreamux/Views/CommitTrailPopover.swift Sources/Dreamux/Views/ContentView.swift
git commit -m "Git chip opens the worktree's commit trail with per-commit diffs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Task rows — "View changes"

**Files:**
- Create: `Sources/Dreamux/Models/TaskDiffResolver.swift`
- Modify: `Sources/Dreamux/Views/PlansSpecsSection.swift` (context-menu item + closure param)
- Modify: `Sources/Dreamux/Views/WorkspaceSidebar.swift` (wire the closure: resolve + open or alert)
- Test: `Tests/DreamuxTests/TaskDiffResolverTests.swift`

**Interfaces:**
- Consumes: `CommitInfo` (Task 1), `DiffRequest`/`openDiffTab` routing (Tasks 4–5), PlansSpecsSection's existing `featureName`/`workspaceForFeature` closures, `GitOperations.worktreeURL/commitLog`.
- Produces: `enum TaskDiffResolver { static func range(for taskTitle: String, in log: [CommitInfo]) -> (from: String, to: String)? }` — pure; log is newest-first as `commitLog` returns it.

- [ ] **Step 1: Write the failing resolver tests**

Create `Tests/DreamuxTests/TaskDiffResolverTests.swift`:

```swift
import XCTest
@testable import Dreamux

/// Maps a task's heading to the commit range that implemented it.
/// Subjects match when they start with the task title (the agent
/// commits the heading verbatim; the backstop appends " (auto)").
final class TaskDiffResolverTests: XCTestCase {
    private func commit(_ sha: String, _ subject: String) -> CommitInfo {
        CommitInfo(sha: sha, shortSHA: String(sha.prefix(7)),
                   subject: subject, authorDate: nil,
                   insertions: 0, deletions: 0)
    }

    /// Single matching commit → parent..commit.
    func testSingleCommit() {
        let log = [commit(String(repeating: "b", count: 40), "Other work"),
                   commit(String(repeating: "a", count: 40), "Task 2: Wire the store")]
        let range = TaskDiffResolver.range(for: "Task 2: Wire the store", in: log)
        XCTAssertEqual(range?.from, String(repeating: "a", count: 40) + "^")
        XCTAssertEqual(range?.to, String(repeating: "a", count: 40))
    }

    /// Several commits (agent commit + backstop " (auto)") → span from
    /// the OLDEST match's parent to the NEWEST match. Log is
    /// newest-first.
    func testMultipleCommitsSpan() {
        let newest = String(repeating: "c", count: 40)
        let oldest = String(repeating: "a", count: 40)
        let log = [commit(newest, "Task 2: Wire the store (auto)"),
                   commit(String(repeating: "b", count: 40), "Unrelated"),
                   commit(oldest, "Task 2: Wire the store")]
        let range = TaskDiffResolver.range(for: "Task 2: Wire the store", in: log)
        XCTAssertEqual(range?.from, oldest + "^")
        XCTAssertEqual(range?.to, newest)
    }

    /// Prefix discipline: "Task 2: Wire" must not match
    /// "Task 2: Wire the store"'s search and vice versa — matching is
    /// title-then-boundary (exact title, or title followed by " (").
    func testNoFalsePrefixMatches() {
        let log = [commit(String(repeating: "a", count: 40), "Task 21: Wireless")]
        XCTAssertNil(TaskDiffResolver.range(for: "Task 2: Wire", in: log))
        XCTAssertNil(TaskDiffResolver.range(for: "Task 21: Wireless extras", in: log))
    }

    func testNoMatchesReturnsNil() {
        XCTAssertNil(TaskDiffResolver.range(for: "Task 9: Ghost", in: []))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TaskDiffResolverTests 2>&1 | tail -10`
Expected: BUILD FAILURE — `cannot find 'TaskDiffResolver' in scope`.

- [ ] **Step 3: Implement the resolver**

Create `Sources/Dreamux/Models/TaskDiffResolver.swift`:

```swift
import Foundation

/// Maps a plan task's heading to the worktree commits that implemented
/// it. Agents commit the heading verbatim; the queue backstop appends
/// " (auto)" — both count. Pure so the matching rules are testable
/// without a repo.
enum TaskDiffResolver {
    /// The revision range covering every commit whose subject is the
    /// task title (exactly, or followed by a " (" suffix like
    /// " (auto)"). `log` is newest-first (GitOperations.commitLog
    /// order). Returns oldest-parent..newest, nil when nothing matches.
    static func range(
        for taskTitle: String,
        in log: [CommitInfo]
    ) -> (from: String, to: String)? {
        let matches = log.filter { commit in
            commit.subject == taskTitle
                || commit.subject.hasPrefix("\(taskTitle) (")
        }
        guard let newest = matches.first, let oldest = matches.last else {
            return nil
        }
        return (from: "\(oldest.sha)^", to: newest.sha)
    }
}
```

- [ ] **Step 4: Run resolver tests**

Run: `swift test --filter TaskDiffResolverTests 2>&1 | tail -5` → 4 tests passed.

- [ ] **Step 5: Wire the UI**

1. `PlansSpecsSection` gains a closure parameter (alongside `onCourseCorrectionNudge` etc.): `let onViewTaskChanges: (PlanDoc, PlanTask) -> Void`. In `taskRow`'s `.contextMenu`, add above "Course correct…":

```swift
        Button("View changes") {
            onViewTaskChanges(plan, task)
        }
```

Also add a hover-revealed button on the row itself (spec asks for both affordances). `taskRow` currently tracks no hover; add `@State private var hoveredTaskLine: Int?` to the section and, in `taskRow`'s label HStack, replace the bare `Text("\(checked)/\(total)")` trailing pair with:

```swift
            if hoveredTaskLine == task.line, checked > 0 {
                Button {
                    onViewTaskChanges(plan, task)
                } label: {
                    Image(systemName: "plus.forwardslash.minus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("View this task's changes")
            }
            Text("\(checked)/\(total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
```

and attach to the returned row (after `.buttonStyle(.plain)`):

```swift
        .onHover { inside in
            if inside { hoveredTaskLine = task.line }
            else if hoveredTaskLine == task.line { hoveredTaskLine = nil }
        }
```

(Hover button appears only when at least one step is checked — an untouched task can't have commits. Deliberate deviation from the spec's "disabled with tooltip when no commit exists": commit existence is async, so the click resolves and explains via the sidebar's error alert instead — see Step 5's no-match message.)

2. In `WorkspaceSidebar` where `PlansSpecsSection(...)` is constructed, pass:

```swift
                onViewTaskChanges: { plan, task in
                    viewTaskChanges(plan: plan, task: task)
                },
```

and add the method (near `openServices`; it reuses the sidebar's existing stores and its existing error surface — find the `addError`/alert state the sidebar already has and use it):

```swift
    /// Resolve the commits recorded for a task (agent + backstop) in
    /// each of the feature's repo worktrees and open a diff tab per
    /// repo with matches. No matches anywhere → explain instead of
    /// silently doing nothing.
    private func viewTaskChanges(plan: PlanDoc, task: PlanTask) {
        let feature = featureName(for: plan)
        guard let workspace = store.workspaces.first(where: { $0.name == feature })
        else {
            addError = "No workspace for this plan yet — run the plan first."
            return
        }
        let repos = repoStore.repositories.filter {
            workspace.linkedRepoIDs.contains($0.name)
        }
        let title = task.title
        Task { @MainActor in
            var opened = 0
            for repo in repos {
                guard let worktree = await GitOperations.worktreeURL(
                    forBranch: feature, in: repo.rootURL) else { continue }
                let log = await GitOperations.commitLog(
                    in: worktree, baseBranch: repo.defaultBranch)
                guard let range = TaskDiffResolver.range(for: title, in: log)
                else { continue }
                sidebarMode = .workspace
                store.activate(workspace.id)
                store.session(for: workspace).openDiffTab(DiffRequest(
                    worktreeURL: worktree,
                    fromRevision: range.from,
                    toRevision: range.to,
                    title: repos.count > 1 ? "\(title) — \(repo.name)" : title))
                opened += 1
            }
            if opened == 0 {
                addError = "No commits recorded for \"\(title)\" yet. The agent commits when the task's boxes are ticked (auto-commit is \(WorkflowSettings.autoCommitEnabled ? "on" : "OFF — see Settings → Workflow"))."
            }
        }
    }
```

(Adapt `addError` to the sidebar's actual error-alert state name after reading it; if `featureName(for:)` has a different spelling at this layer, use the section's existing closure source. If `PlansSpecsSection` has other construction sites — previews, tests — pass a no-op closure there.)

- [ ] **Step 6: Full suite, commit**

Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1` → 0 failures.

```bash
git add Sources/Dreamux/Models/TaskDiffResolver.swift Sources/Dreamux/Views/PlansSpecsSection.swift Sources/Dreamux/Views/WorkspaceSidebar.swift Tests/DreamuxTests/TaskDiffResolverTests.swift
git commit -m "Task rows resolve their commits into a View Changes diff

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: End-to-end verification + merge gate

**Files:** none (verification + git only)

- [ ] **Step 1: Build + relaunch from the worktree**

```bash
./Scripts/make-app.sh
PID=$(pgrep -x Dreamux); if [ -n "$PID" ]; then kill -TERM "$PID"; while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done; fi
open ./Dreamux.app --args -ApplePersistenceIgnoreState YES
sleep 4
```

- [ ] **Step 2: Screenshot verification** (established workflow: winid.swift + `screencapture -x -o -l`, pixel-check when contested; save to the session scratchpad)

- Click the git chip → popover shows commits with SHAs/±stats (and "Uncommitted changes" on a dirty worktree). Screenshot.
- Click a commit → a diff tab opens: file rail left, Monaco side-by-side right, read-only. Screenshot.
- Task row context menu shows "View changes". Screenshot.
- Settings (⌘,) shows the Workflow section with the toggle ON. Screenshot.
- If screen capture is unavailable, report DONE_WITH_CONCERNS — the controller/user verify visually.

- [ ] **Step 3: Backstop sanity in a scratch repo** (no live plan needed)

The queue backstop path is unit-tested; verify the commit plumbing end-to-end by hand: in a scratch repo with uncommitted changes, run the exact operation the wiring performs (`GitOperations.commitAll(message: "Task 1: Test (auto)")` — covered by GitCommitLogTests fixtures already exercising commitAll indirectly). Confirm nothing further needed; note in the report that live plan-run verification happens on the user's next real plan.

- [ ] **Step 4: Present results to the user and wait for merge approval.** Do not merge without it.

- [ ] **Step 5: Merge and push (after approval)**

```bash
cd /Users/olliejarvis/Development/clayspace
git status --short && git log --oneline -1
git merge --ff-only auto-commit-diffs || git merge --no-edit auto-commit-diffs
swift test 2>&1 | grep -E "Executed .* tests" | tail -1
git push origin main
git worktree remove .claude/worktrees/auto-commit-diffs
git branch -d auto-commit-diffs
./Scripts/make-app.sh
PID=$(pgrep -x Dreamux); if [ -n "$PID" ]; then kill -TERM "$PID"; while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done; fi
open /Users/olliejarvis/Development/clayspace/Dreamux.app
```

Expected: ff merge (re-verify SHAs — main may move from parallel sessions), suite green on main, push accepted, canonical app relaunched from main.
