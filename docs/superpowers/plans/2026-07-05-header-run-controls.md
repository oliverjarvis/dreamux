# Header Run Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A play/stop capsule + services popover in the card's context header (left of the git chip) that starts/stops the active workspace's runners, lists every service with port/status/actions, and jumps to Signals filtered per service.

**Architecture:** Pure aggregation functions on `RunnerManager` (new `RunnerHeaderState.swift`) compute the capsule summary and popover rows from existing instance state — unit-testable with fabricated dictionaries, no processes. A new `HeaderRunControls` view renders them, following `WorkspaceRunControls`' injection pattern (state derived from the manager, navigation actions injected). ContentView wires it into `contextHeaderRow` reusing `startPlan`/`executeStart`/`stop` exactly as the sidebar does. The "logs" jump parks a runner name on `SignalStore.pendingSourceFocus` (the established `pendingIsolation` pattern), consumed by `SignalsView.onAppear`.

**Tech Stack:** Swift / SwiftPM, SwiftUI, XCTest (`@MainActor`, `TestSandbox` fixture). No new dependencies.

## Global Constraints

- Platform floor: `macOS(.v14)` (Package.swift) — `.symbolEffect(.pulse)` is available.
- All manager/model code is `@MainActor @Observable` (match `RunnerManager`).
- UI copy/typography: match the git chip (font size 11, capsule `Color.primary.opacity(0.05)`, h-padding 8, v-padding 3); sidebar-adjacent text uses `.callout`/`.caption`, never `.caption2` cramp for primary labels.
- Tests: XCTest in `Tests/DreamuxTests/`, `@MainActor final class … : XCTestCase`, doc comments explaining the *why* of each test (house style).
- Git: stage only named files (`git add <paths>`, never `-A` — parallel sessions may touch main). Commit messages are plain sentences (e.g. "File tree slides in under the context header"), each ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Full `swift test` must pass before the final commit of each task.
- The delivery branch is `header-run-controls`; merge to main only after the user approves the screenshots (Task 5).

**Existing API this plan consumes (all in `Sources/Dreamux/Models/RunnerManager.swift` unless noted):**
- `ParsedRunner` (`name/cwd/start/stop/port/portEnv/open`), `RunnerStatus` (`.idle/.running(pid:)/.exited(code:)/.failed(message:)`, `isRunning`), `RunnerInstanceKey(runnerName:branch:)`
- `RunnerManager.runners: [ParsedRunner]`, `statusByInstance: [RunnerInstanceKey: RunnerStatus]` (read), `assignedPorts: [RunnerInstanceKey: Int]` (read)
- `startPlan(for:) -> StartPlan` (`.openRunPane` / `.start(toStart:displacing:)`), `executeStart(_:)`, `stop(_:on:)`, `restart(_:) async`, `start(_:)`, `setActiveBranch(_:for:)`
- `runnersAssociated(with:)`, `runningRunners(onBranch:)`, `canOpen(_:)`, `openNow(_:on:preferExternal:)`, `status(for:on:)`
- `SignalStore` (`Sources/Dreamux/Models/Signal.swift`): `knownSources: [String]`
- `Workspace.name` is the branch name; `SidebarMode` (`ContentView.swift:561`): `.workspace / .run(workspaceID: UUID) / .signals`
- ContentView already holds `store` (WorkspaceStore), `runners`, `signals`, `runConfig`, `sidebarMode`, and `contextHeaderRow` (ContentView.swift:431–491) with the git chip at lines 440–469.

---

### Task 1: Branch + header aggregation model

**Files:**
- Create: `Sources/Dreamux/Models/RunnerHeaderState.swift`
- Test: `Tests/DreamuxTests/RunnerHeaderStateTests.swift`

**Interfaces:**
- Consumes: `ParsedRunner`, `RunnerStatus`, `RunnerInstanceKey`, `RunnerManager` state maps.
- Produces (used by Tasks 3–4):
  - `struct HeaderRunSummary: Equatable { var hasConfig: Bool; var runningCount: Int; var attention: Bool }`
  - `struct HeaderServiceRow: Identifiable, Equatable { let runner: ParsedRunner; let branch: String; let status: RunnerStatus; let port: Int?; var id: String }`
  - `RunnerManager.headerSummary(for: Workspace) -> HeaderRunSummary`
  - `RunnerManager.serviceRows(for: Workspace) -> [HeaderServiceRow]`
  - `RunnerManager.otherWorktreeRows(excluding: Workspace) -> [HeaderServiceRow]`
  - Static equivalents used by tests: `RunnerManager.headerSummary(associated:statuses:branch:hasConfig:)`, `.serviceRows(associated:statuses:assignedPorts:branch:)`, `.otherWorktreeRows(allRunners:statuses:assignedPorts:excludingBranch:)`

- [ ] **Step 1: Create the working branch**

```bash
cd /Users/olliejarvis/Development/clayspace
git checkout -b header-run-controls
```

(If executing from an isolated worktree instead: `git worktree add .claude/worktrees/header-run-controls -b header-run-controls` and work there.)

- [ ] **Step 2: Write the failing tests**

Create `Tests/DreamuxTests/RunnerHeaderStateTests.swift`:

```swift
import XCTest
@testable import Dreamux

/// Pure-logic coverage for the header run cluster's aggregation: the
/// play/stop capsule summary and the services-popover rows. Everything
/// goes through the static functions with fabricated state dictionaries
/// — no subprocess is ever spawned, mirroring RunnerManagerLogicTests.
@MainActor
final class RunnerHeaderStateTests: XCTestCase {

    private func runner(
        name: String = "web",
        port: Int? = nil,
        portEnv: String? = nil,
        open: String? = nil
    ) -> ParsedRunner {
        ParsedRunner(
            name: name, cwd: "repos/\(name)/main", start: "echo hi",
            stop: nil, port: port, portEnv: portEnv, open: open)
    }

    private func key(_ name: String, _ branch: String) -> RunnerInstanceKey {
        RunnerInstanceKey(runnerName: name, branch: branch)
    }

    // MARK: - headerSummary

    /// No run.toml → the capsule's only job is opening the Run pane.
    func testSummaryWithoutConfig() {
        let summary = RunnerManager.headerSummary(
            associated: [], statuses: [:], branch: "feat", hasConfig: false)
        XCTAssertEqual(
            summary,
            HeaderRunSummary(hasConfig: false, runningCount: 0, attention: false))
    }

    /// Only instances on the scope's branch count — a runner alive on
    /// another worktree must not flip the capsule to "running".
    func testSummaryCountsOnlyScopeBranch() {
        let web = runner(name: "web")
        let api = runner(name: "api")
        let statuses: [RunnerInstanceKey: RunnerStatus] = [
            key("web", "feat"): .running(pid: 11),
            key("api", "other"): .running(pid: 22),
        ]
        let summary = RunnerManager.headerSummary(
            associated: [web, api], statuses: statuses, branch: "feat", hasConfig: true)
        XCTAssertEqual(summary.runningCount, 1)
        XCTAssertFalse(summary.attention)
    }

    /// Attention (amber dot): a failed start or a non-zero exit on the
    /// scope's branch. A clean exit is not attention-worthy.
    func testSummaryAttention() {
        let web = runner(name: "web")
        let api = runner(name: "api")
        let db = runner(name: "db")

        let failed = RunnerManager.headerSummary(
            associated: [web],
            statuses: [key("web", "feat"): .failed(message: "port in use")],
            branch: "feat", hasConfig: true)
        XCTAssertTrue(failed.attention)

        let crashed = RunnerManager.headerSummary(
            associated: [api],
            statuses: [key("api", "feat"): .exited(code: 1)],
            branch: "feat", hasConfig: true)
        XCTAssertTrue(crashed.attention)

        let cleanExit = RunnerManager.headerSummary(
            associated: [db],
            statuses: [key("db", "feat"): .exited(code: 0)],
            branch: "feat", hasConfig: true)
        XCTAssertFalse(cleanExit.attention)
    }

    // MARK: - serviceRows

    /// One row per associated runner, in run.toml order; instances the
    /// scope never started show as .idle; the assigned (per-worktree)
    /// port wins over the declared one so the row shows where the
    /// server actually listens.
    func testServiceRowsPortAndStatusResolution() {
        let web = runner(name: "web", port: 3000, portEnv: "WEB_PORT")
        let api = runner(name: "api", port: 4000)
        let rows = RunnerManager.serviceRows(
            associated: [web, api],
            statuses: [key("web", "feat"): .running(pid: 9)],
            assignedPorts: [key("web", "feat"): 3002],
            branch: "feat")

        XCTAssertEqual(rows.map(\.id), ["web@feat", "api@feat"])
        XCTAssertEqual(rows[0].status, .running(pid: 9))
        XCTAssertEqual(rows[0].port, 3002, "assigned per-worktree port wins")
        XCTAssertEqual(rows[1].status, .idle, "never started here → idle")
        XCTAssertEqual(rows[1].port, 4000, "no assignment → declared port")
    }

    // MARK: - otherWorktreeRows

    /// Only *live* instances on other branches appear (a stopped one is
    /// not "invisible running state"); scope-branch instances are the
    /// active list's job; stale statuses whose runner left run.toml are
    /// skipped; output order is deterministic.
    func testOtherWorktreeRows() {
        let web = runner(name: "web", port: 3000)
        let api = runner(name: "api")
        let statuses: [RunnerInstanceKey: RunnerStatus] = [
            key("web", "main"): .running(pid: 1),
            key("web", "feat"): .running(pid: 2),   // scope → excluded
            key("api", "main"): .exited(code: 0),   // dead → excluded
            key("gone", "main"): .running(pid: 3),  // not in run.toml → skipped
        ]
        let rows = RunnerManager.otherWorktreeRows(
            allRunners: [web, api],
            statuses: statuses,
            assignedPorts: [key("web", "main"): 3001],
            excludingBranch: "feat")

        XCTAssertEqual(rows.map(\.id), ["web@main"])
        XCTAssertEqual(rows[0].port, 3001)
        XCTAssertEqual(rows[0].branch, "main")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter RunnerHeaderStateTests 2>&1 | tail -20`
Expected: BUILD FAILURE — `cannot find 'HeaderRunSummary' in scope` (and friends). That's the red state.

- [ ] **Step 4: Write the implementation**

Create `Sources/Dreamux/Models/RunnerHeaderState.swift`:

```swift
import Foundation

/// Snapshot driving the header's play/stop capsule for the active
/// workspace. `runningCount` counts associated runners with a live
/// instance on the scope's branch; `attention` is true when any scope
/// instance failed to start or exited non-zero — the capsule renders
/// it as an amber dot.
struct HeaderRunSummary: Equatable {
    var hasConfig: Bool
    var runningCount: Int
    var attention: Bool
}

/// One row in the header's services popover: a runner pinned to a
/// specific branch, with its live status and the port it actually
/// listens on (per-worktree assignment first, declared port second).
struct HeaderServiceRow: Identifiable, Equatable {
    let runner: ParsedRunner
    let branch: String
    let status: RunnerStatus
    let port: Int?
    var id: String { "\(runner.name)@\(branch)" }
}

/// Header aggregation lives in static functions so the exact logic the
/// capsule renders is unit-testable with fabricated dictionaries — the
/// same decision/execution split `startPlan(for:)` uses. The instance
/// conveniences feed them live state.
extension RunnerManager {

    // MARK: - Pure aggregation

    static func headerSummary(
        associated: [ParsedRunner],
        statuses: [RunnerInstanceKey: RunnerStatus],
        branch: String,
        hasConfig: Bool
    ) -> HeaderRunSummary {
        var running = 0
        var attention = false
        for runner in associated {
            switch statuses[RunnerInstanceKey(runnerName: runner.name, branch: branch)] {
            case .running:
                running += 1
            case .failed:
                attention = true
            case .exited(let code) where code != 0:
                attention = true
            default:
                break
            }
        }
        return HeaderRunSummary(
            hasConfig: hasConfig, runningCount: running, attention: attention)
    }

    static func serviceRows(
        associated: [ParsedRunner],
        statuses: [RunnerInstanceKey: RunnerStatus],
        assignedPorts: [RunnerInstanceKey: Int],
        branch: String
    ) -> [HeaderServiceRow] {
        associated.map { runner in
            let key = RunnerInstanceKey(runnerName: runner.name, branch: branch)
            return HeaderServiceRow(
                runner: runner,
                branch: branch,
                status: statuses[key] ?? .idle,
                port: assignedPorts[key] ?? runner.port)
        }
    }

    static func otherWorktreeRows(
        allRunners: [ParsedRunner],
        statuses: [RunnerInstanceKey: RunnerStatus],
        assignedPorts: [RunnerInstanceKey: Int],
        excludingBranch branch: String
    ) -> [HeaderServiceRow] {
        var rows: [HeaderServiceRow] = []
        for (key, status) in statuses
        where status.isRunning && key.branch != branch {
            // A status can outlive its runner (removed from run.toml
            // while running is prevented by reload's cleanup, but be
            // defensive) — no definition, no row.
            guard let runner = allRunners.first(where: { $0.name == key.runnerName })
            else { continue }
            rows.append(HeaderServiceRow(
                runner: runner,
                branch: key.branch,
                status: status,
                port: assignedPorts[key] ?? runner.port))
        }
        return rows.sorted {
            ($0.runner.name, $0.branch) < ($1.runner.name, $1.branch)
        }
    }

    // MARK: - Live conveniences (what HeaderRunControls calls)

    func headerSummary(for workspace: Workspace) -> HeaderRunSummary {
        Self.headerSummary(
            associated: runnersAssociated(with: workspace),
            statuses: statusByInstance,
            branch: workspace.name,
            hasConfig: !runners.isEmpty)
    }

    func serviceRows(for workspace: Workspace) -> [HeaderServiceRow] {
        Self.serviceRows(
            associated: runnersAssociated(with: workspace),
            statuses: statusByInstance,
            assignedPorts: assignedPorts,
            branch: workspace.name)
    }

    func otherWorktreeRows(excluding workspace: Workspace) -> [HeaderServiceRow] {
        Self.otherWorktreeRows(
            allRunners: runners,
            statuses: statusByInstance,
            assignedPorts: assignedPorts,
            excludingBranch: workspace.name)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter RunnerHeaderStateTests 2>&1 | tail -5`
Expected: `Test Suite 'RunnerHeaderStateTests' passed` — 5 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/Dreamux/Models/RunnerHeaderState.swift Tests/DreamuxTests/RunnerHeaderStateTests.swift
git commit -m "Header run aggregation: capsule summary and service rows

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Signals source focus (the popover's "logs" jump)

**Files:**
- Modify: `Sources/Dreamux/Models/Signal.swift` (inside `final class SignalStore`, near `knownSources` ~line 60)
- Modify: `Sources/Dreamux/Views/SignalsView.swift:46-52` (the `.onAppear` block)
- Test: `Tests/DreamuxTests/SignalSourceFocusTests.swift`

**Interfaces:**
- Consumes: `SignalStore.knownSources`; `SignalsView`'s existing `enabledSources: Set<String>` state and `allKnownSources` computed property.
- Produces (used by Tasks 3–4): `SignalStore.pendingSourceFocus: String?` (park-and-consume), `SignalStore.sourcesMatching(focus:in:) -> Set<String>`.

Background: runner log sources are named by `RunnerManager.signalSource(runnerName:branch:)` (private, RunnerManager.swift:787) — the bare runner name when one branch emits, `name:branch` once several do. The focus filter therefore matches by name-or-`name:`-prefix rather than exact string.

- [ ] **Step 1: Write the failing tests**

Create `Tests/DreamuxTests/SignalSourceFocusTests.swift`:

```swift
import XCTest
@testable import Dreamux

/// The header popover's "logs" button focuses SignalsView on one
/// runner. Sources are `name` or `name:branch` depending on how many
/// branches ever emitted (RunnerManager.signalSource), so the match is
/// name-or-prefix — and must not swallow *other* runners that merely
/// share a name prefix.
@MainActor
final class SignalSourceFocusTests: XCTestCase {

    func testMatchesBareNameAndBranchVariants() {
        let sources = ["web", "web:feat", "web:main", "api"]
        XCTAssertEqual(
            SignalStore.sourcesMatching(focus: "web", in: sources),
            ["web", "web:feat", "web:main"])
    }

    func testPrefixWithoutColonIsNotAMatch() {
        XCTAssertEqual(
            SignalStore.sourcesMatching(focus: "web", in: ["webapp", "web:feat"]),
            ["web:feat"],
            "'webapp' shares a prefix but is a different runner")
    }

    /// Focusing before the runner ever logged: fall back to the bare
    /// name so the chip exists and lights up when lines arrive.
    func testNoKnownSourcesFallsBackToFocusName() {
        XCTAssertEqual(
            SignalStore.sourcesMatching(focus: "web", in: ["api"]),
            ["web"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SignalSourceFocusTests 2>&1 | tail -10`
Expected: BUILD FAILURE — `type 'SignalStore' has no member 'sourcesMatching'`.

- [ ] **Step 3: Implement on SignalStore**

In `Sources/Dreamux/Models/Signal.swift`, inside `SignalStore` (after the `knownSources` declarations):

```swift
    /// A runner name the Signals page should focus its source filter
    /// on the next time it appears — parked by the header's services
    /// popover ("logs"), consumed and cleared by SignalsView.onAppear.
    /// The `RunnerManager.pendingIsolation` pattern again.
    var pendingSourceFocus: String?

    /// Sources belonging to one runner: the bare name plus any
    /// `name:branch` variants (see RunnerManager.signalSource). Falls
    /// back to the bare name when nothing matches yet, so focusing
    /// before the first log line still yields a filter that lights up
    /// once lines arrive.
    static func sourcesMatching(focus: String, in sources: [String]) -> Set<String> {
        let hits = sources.filter { $0 == focus || $0.hasPrefix("\(focus):") }
        return hits.isEmpty ? [focus] : Set(hits)
    }
```

- [ ] **Step 4: Consume the focus in SignalsView**

In `Sources/Dreamux/Views/SignalsView.swift`, replace the existing `.onAppear` block (lines 46–52):

```swift
        .onAppear {
            if let focus = signals.pendingSourceFocus {
                // Arriving from a service row's "logs" button: show
                // just that runner's sources. The chip row is right
                // there for widening back out.
                signals.pendingSourceFocus = nil
                enabledSources = SignalStore.sourcesMatching(
                    focus: focus, in: allKnownSources)
            } else if enabledSources.isEmpty {
                // Seed the source filter with everything we currently know
                // about; the user can opt sources out from the chip row.
                enabledSources = Set(allKnownSources)
            }
        }
```

(The existing `.onChange(of: signals.knownSources)` auto-include stays as-is: a *newly appearing* source widening a focused view is live-tail-friendly behavior, and the focus is a one-shot jump, not a mode.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter SignalSourceFocusTests 2>&1 | tail -5`
Expected: `Test Suite 'SignalSourceFocusTests' passed` — 3 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/Dreamux/Models/Signal.swift Sources/Dreamux/Views/SignalsView.swift Tests/DreamuxTests/SignalSourceFocusTests.swift
git commit -m "Signals can open focused on one runner's sources

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: HeaderRunControls view

**Files:**
- Create: `Sources/Dreamux/Views/HeaderRunControls.swift`

**Interfaces:**
- Consumes: `HeaderRunSummary`, `HeaderServiceRow`, `RunnerManager.headerSummary(for:)/serviceRows(for:)/otherWorktreeRows(excluding:)` (Task 1); `RunnerManager.canOpen/openNow/stop/start/setActiveBranch/restart`; `Workspace`.
- Produces (used by Task 4): `struct HeaderRunControls: View` with init `(workspace: Workspace, runners: RunnerManager, start: @escaping () -> Void, stop: @escaping () -> Void, openRunPane: @escaping () -> Void, showLogs: @escaping (_ runnerName: String) -> Void)`.

No unit test — pure view; behavior lives in Tasks 1–2's tested models. Verification is the build + Task 4's screenshots.

- [ ] **Step 1: Write the view**

Create `Sources/Dreamux/Views/HeaderRunControls.swift`:

```swift
import SwiftUI

/// The context header's run cluster: a play/stop capsule and a services
/// popover, sitting left of the git chip. Status derives from the
/// shared `RunnerManager` (via the tested aggregation in
/// RunnerHeaderState.swift); actions that navigate — starting the scope
/// (which may need the Run pane), editing run config, jumping to
/// Signals — are injected because they drive `sidebarMode`, which the
/// owning view controls. Mirrors `WorkspaceRunControls`' split.
struct HeaderRunControls: View {
    let workspace: Workspace
    let runners: RunnerManager
    let start: () -> Void
    let stop: () -> Void
    let openRunPane: () -> Void
    let showLogs: (_ runnerName: String) -> Void

    @State private var showServices = false
    @State private var hoveredRowID: String?

    var body: some View {
        let summary = runners.headerSummary(for: workspace)
        HStack(spacing: 2) {
            playCapsule(summary)
            if summary.hasConfig {
                chevronButton
            }
        }
        .popover(isPresented: $showServices, arrowEdge: .bottom) {
            servicesPopover
        }
    }

    // MARK: - Capsule

    private func playCapsule(_ summary: HeaderRunSummary) -> some View {
        Button {
            if !summary.hasConfig {
                openRunPane()
            } else if summary.runningCount > 0 {
                stop()
            } else {
                start()
            }
        } label: {
            HStack(spacing: 5) {
                if summary.runningCount > 0 {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(summary.attention ? Color.orange : Color.green)
                        .symbolEffect(.pulse)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("\(summary.runningCount) running")
                        .foregroundStyle(.secondary)
                } else {
                    if summary.attention {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(Color.orange)
                    }
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(playHelp(summary))
    }

    private func playHelp(_ summary: HeaderRunSummary) -> String {
        if !summary.hasConfig { return "Set up run configuration" }
        if summary.runningCount > 0 { return "Stop \(workspace.name)'s services" }
        return "Start \(workspace.name)'s services"
    }

    private var chevronButton: some View {
        Button {
            showServices.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Services")
    }

    // MARK: - Popover

    private var servicesPopover: some View {
        let active = runners.serviceRows(for: workspace)
        let other = runners.otherWorktreeRows(excluding: workspace)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(active) { row in
                    serviceRow(row, inScope: true)
                }
            }
            .padding(8)

            if !other.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Other worktrees")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                    ForEach(other) { row in
                        serviceRow(row, inScope: false)
                    }
                }
                .padding(8)
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    /// One service line: status dot · name · (branch when out of scope)
    /// · port, with hover-revealed actions. In-scope rows get the full
    /// set (open/logs/restart/stop-or-start); other-worktree rows only
    /// open/logs/stop — restarting or starting them belongs to *their*
    /// workspace's play button.
    private func serviceRow(_ row: HeaderServiceRow, inScope: Bool) -> some View {
        let hovered = hoveredRowID == row.id
        return HStack(spacing: 8) {
            Circle()
                .fill(statusColor(row.status))
                .frame(width: 7, height: 7)

            Text(row.runner.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)

            if !inScope {
                Text(row.branch)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if let port = row.port {
                Text(":\(String(port))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if hovered {
                rowActions(row, inScope: inScope)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.06) : .clear))
        .onHover { inside in
            if inside {
                hoveredRowID = row.id
            } else if hoveredRowID == row.id {
                hoveredRowID = nil
            }
        }
        .help(rowHelp(row))
    }

    @ViewBuilder
    private func rowActions(_ row: HeaderServiceRow, inScope: Bool) -> some View {
        HStack(spacing: 6) {
            if runners.canOpen(row.runner) {
                iconButton("safari", help: "Open in browser") {
                    runners.openNow(row.runner, on: row.branch)
                }
            }
            iconButton("waveform.path.ecg", help: "View logs in Signals") {
                showServices = false
                showLogs(row.runner.name)
            }
            if row.status.isRunning {
                if inScope {
                    iconButton("arrow.clockwise", help: "Restart") {
                        Task { await runners.restart(row.runner) }
                    }
                }
                iconButton("stop.fill", help: "Stop") {
                    runners.stop(row.runner, on: row.branch)
                }
            } else if inScope {
                iconButton("play.fill", help: "Start") {
                    // Pin the runner to this workspace's worktree first —
                    // a single-row start must not launch on whatever
                    // branch a previous session left active.
                    runners.setActiveBranch(workspace.name, for: row.runner)
                    runners.start(row.runner)
                }
            }
        }
    }

    private func iconButton(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func statusColor(_ status: RunnerStatus) -> Color {
        switch status {
        case .running:
            return .green
        case .failed:
            return .orange
        case .exited(let code):
            return code == 0 ? Color.secondary.opacity(0.5) : .orange
        case .idle:
            return Color.secondary.opacity(0.4)
        }
    }

    private func rowHelp(_ row: HeaderServiceRow) -> String {
        switch row.status {
        case .running(let pid):
            return "\(row.runner.name) on \(row.branch) — running (pid \(pid))"
        case .failed(let message):
            return "\(row.runner.name) on \(row.branch) — \(message)"
        case .exited(let code):
            return "\(row.runner.name) on \(row.branch) — exited (\(code))"
        case .idle:
            return "\(row.runner.name) on \(row.branch) — not running"
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Start all") {
                showServices = false
                start()
            }
            Button("Stop all") {
                showServices = false
                stop()
            }
            Spacer(minLength: 0)
            Button {
                showServices = false
                openRunPane()
            } label: {
                Label("Edit run config", systemImage: "slider.horizontal.3")
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build 2>&1 | grep "error:" | head; echo BUILD-DONE`
Expected: no error lines, then `BUILD-DONE`. (House rule: never `grep -c` in an `&&` chain — it exits 1 on zero matches.)

- [ ] **Step 3: Commit**

```bash
git add Sources/Dreamux/Views/HeaderRunControls.swift
git commit -m "Header run cluster view: play capsule and services popover

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Wire into the context header + full verification

**Files:**
- Modify: `Sources/Dreamux/Views/ContentView.swift:431-491` (`contextHeaderRow`) and add two private funcs near `resolveGitStatus` (~line 496)

**Interfaces:**
- Consumes: `HeaderRunControls` (Task 3), `SignalStore.pendingSourceFocus` (Task 2), existing `store.activeWorkspace`, `runners.startPlan/executeStart/stop/status(for:on:)`, `sidebarMode`.
- Produces: the shipped feature.

- [ ] **Step 1: Insert the cluster into contextHeaderRow**

In `Sources/Dreamux/Views/ContentView.swift`, inside `contextHeaderRow`'s `HStack`, directly after `Spacer(minLength: 0)` (line 437) and before the `if let git = gitStatus` chip:

```swift
            // Run cluster: play/stop for the active workspace's
            // services, plus the services popover. Left of the git chip
            // so the header reads context → run state → repo state.
            if let workspace = store.activeWorkspace {
                HeaderRunControls(
                    workspace: workspace,
                    runners: runners,
                    start: { startHeaderRunners(for: workspace) },
                    stop: { stopHeaderRunners(for: workspace) },
                    openRunPane: {
                        sidebarMode = .run(workspaceID: workspace.id)
                    },
                    showLogs: { runnerName in
                        signals.pendingSourceFocus = runnerName
                        sidebarMode = .signals
                    })
            }
```

- [ ] **Step 2: Add the start/stop helpers**

In the same file, after `resolveGitStatus` (below line 511):

```swift
    /// Header play: the same planning the sidebar rows use — `startPlan`
    /// decides, `executeStart` acts. The sidebar's displacement banner
    /// is deliberately not duplicated here; a fixed-port switch still
    /// happens, and the popover's "Other worktrees" group shows the
    /// result.
    private func startHeaderRunners(for workspace: Workspace) {
        switch runners.startPlan(for: workspace) {
        case .openRunPane:
            sidebarMode = .run(workspaceID: workspace.id)
        case .start(let toStart, _):
            runners.executeStart(toStart)
        }
    }

    /// Header stop: every live instance on this workspace's worktree —
    /// mirrors the sidebar's `stopAllRunning(on:)`, per-instance so
    /// other worktrees keep running.
    private func stopHeaderRunners(for workspace: Workspace) {
        for runner in runners.runners
        where runners.status(for: runner, on: workspace.name)?.isRunning == true {
            runners.stop(runner, on: workspace.name)
        }
    }
```

- [ ] **Step 3: Run the full test suite**

Run: `swift test 2>&1 | tail -3`
Expected: `Test Suite 'All tests' passed` (410+ tests, 0 failures).

- [ ] **Step 4: Build the app bundle and relaunch**

```bash
./scripts/make-app.sh
PID=$(pgrep -x Dreamux); if [ -n "$PID" ]; then kill -TERM "$PID"; while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done; fi
open /Users/olliejarvis/Development/clayspace/Dreamux.app
```

(PID-strict quit — never `pkill Dreamux`. If launching a sandbox bundle manually instead, add `-ApplePersistenceIgnoreState YES`.)

- [ ] **Step 5: Screenshot verification**

Capture via the established focus-free workflow and confirm by pixels, not eyeballs:

```bash
WID=$(swift /private/tmp/claude-501/-Users-olliejarvis-Development-clayspace/8eef4089-452c-4b8f-8ea2-f5131b13692e/scratchpad/winid.swift)
screencapture -x -o -l "$WID" /private/tmp/claude-501/-Users-olliejarvis-Development-clayspace/8eef4089-452c-4b8f-8ea2-f5131b13692e/scratchpad/header-run.png
```

Verify (Read the PNG; PIL-sample if contested): capsule visible left of the git chip at the same 36pt header height; play icon idle; after starting a runner (project with run.toml): "N running" + green dot, popover rows show name/port/status dot, "logs" lands on Signals filtered to that runner. Show the user the screenshots.

- [ ] **Step 6: Commit**

```bash
git add Sources/Dreamux/Views/ContentView.swift
git commit -m "Play button and services dropdown join the context header

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Merge gate (user approval required)

**Files:** none (git only)

- [ ] **Step 1: Present screenshots to the user and wait for approval.** Do not merge without it.

- [ ] **Step 2: Merge and push (after approval)**

```bash
cd /Users/olliejarvis/Development/clayspace
git checkout main && git pull --ff-only 2>/dev/null; git status --short
git merge --ff-only header-run-controls || git merge --no-edit header-run-controls
swift test 2>&1 | tail -3
git push origin main
git branch -d header-run-controls
```

Expected: merge succeeds (ff when main hasn't moved; user amends main from parallel sessions — re-verify SHAs before and after), full suite green on main, push accepted.

- [ ] **Step 3: Rebuild the canonical bundle from main and relaunch** (same commands as Task 4 Step 4).
