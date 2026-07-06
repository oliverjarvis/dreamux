# Flows Group 4 — Loop Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The "it's stuck in a loop" glance: a conservative signature heuristic over each hot session's tool completions produces live `.loop` self-edges with iteration counts — rendered as ↺ ×N badges on lanes and dashed self-loops in the zoom DAG — plus the Group 3 rider fixes (pool hygiene, tailer cap accounting, polish) and a live-validation pass.

**Architecture:** `LoopDetector` is a pure function over a per-lane ring of tool completions (signature + isError); `FlowStore` captures signatures at `toolStarted`, correlates at `toolFinished`, runs the detector, and upserts/clears one `.loop` self-edge on the session node. Views render the edge (badge + dashed arc). Everything stays a badge, never a judgment — the UI never claims the loop is stuck. Riders harden `FlowTailerPool` (mtime-gated cached meta parsing off the main thread, dynamic ranking that makes re-promotion live) and `ClaudeTranscriptTailer` (cap-overflow accounting).

**Tech Stack:** Swift 6 / SwiftPM, XCTest, e2e harness.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-06-flows-observatory-design.md` (Loop detection section). Groups 1–3 merged (main at b60308a).
- Heuristic exactness (the contract): signature = tool name for non-Bash tools; `"Bash:" + <first whitespace-separated token of the summary>` for Bash. Window = the lane's last 12 tool completions. A loop reports when one signature has ≥3 occurrences in the window AND ≥2 of them have `isError == true` AND its MOST RECENT occurrence has `isError == true`. Reported count = that signature's occurrence count in the window. Multiple candidates → most occurrences, tie → most recently completed. The loop CLEARS when the signature's newest completion succeeds (isError false) or the signature ages out of the window.
- Loop state is one self-edge per lane: `FlowEdge(from: "session", to: "session", kind: .loop, label: <signature>, iterations: <count>)` — at most ONE loop edge per lane (replace on change, remove on clear).
- Agent-result completions (ids in the toolUse→agent join map) are EXCLUDED from loop tracking — agents aren't repeated commands.
- Scheduled lanes never use the heuristic (recurrence is declared); enforce at the store level (skip lanes with kind .scheduled).
- Degrade never break; no new dependencies; stage only named files; `swift test --filter X`; timing suites run twice.
- Documented limitation (do NOT attempt): `.failed`/loop evidence is inert for team sessions whose metas lack toolUseId.

## Adaptation ground rules

Tasks 1 and 6 carry complete/near-complete code. Tasks 2–5, 7–8 are enumerated-spec tasks against files you have current anchors for (all shapes below verified at b60308a):

- `FlowStore.swift`: `apply(transcript:sessionID:)` switch (toolStarted sets session lastActivity; toolFinished consults `agentIDByToolUse`), private dicts (`pendingSpawns`, `agentIDByToolUse`, `skippedByLane`) swept in `completeSessionNodes`; `insertBeforeDrain`; four fetch-or-make `lane(for:)`-shaped boilerplate copies (Task 6 dedups them).
- `ClaudeFlowAdapter.swift`: `TranscriptEvent.toolStarted(toolUseID:tool:summary:at:)` / `.toolFinished(toolUseID:isError:at:)`.
- `FlowTailerPool.swift`: `scanSubagentsDir` (parses ALL metas inline on the MAIN queue per dir event — Task 4 fixes), `agentFileModDates` (written once at discovery — Task 4 makes dynamic), `enforceAgentTailerCap` (cap 24, `everStartedAgentTailerIDs` gates start-vs-resume; re-promotion currently unreachable), `SessionState` (no deinit; watcher fd leaks at dealloc), accepted-race comment cross-reference gap, `liveAgentTailerIDs` test seam, cap test's overclaiming discrimination comment.
- `ClaudeTranscriptTailer.swift`: `readAvailable` partial-cap drop discards complete lines uncounted (Task 5); `resume()`; delivery Box.
- `FlowLaneView.swift` (badge spot: header HStack after sessionChip), `FlowDetailView.swift` (Canvas edge pass — self-edge from==to needs an arc, `.loop` dashed), `FlowsOverviewView.swift` (zoom binding; stale-lane guard in Task 6), `FlowLayoutEngine.swift` (cycle-safe already; per-rank centering comment overclaims — Task 6 fixes comment only).
- `E2ECommands.flowsState` `flowLanePayload` (nodes only — Task 3 adds edges), PROTOCOL.md, `scenario_flows` in driver.py (writes synthetic transcript + metas; extend for the loop in Task 7), `validate-flows-live.sh` + `LiveShapeValidationTests` (Task 8 extends).

---

### Task 1: LoopDetector (pure)

**Files:**
- Create: `Sources/Dreamux/Models/LoopDetector.swift`
- Test: `Tests/DreamuxTests/LoopDetectorTests.swift`

**Interfaces:**
- Produces (Task 2 relies on exact names):

```swift
struct ToolCompletion: Equatable, Sendable {
    let signature: String
    let isError: Bool
    let at: Date?
}
struct DetectedLoop: Equatable, Sendable {
    let signature: String
    let count: Int
}
enum LoopDetector {
    static let windowSize = 12
    static func signature(tool: String, summary: String?) -> String
    static func detect(window: [ToolCompletion]) -> DetectedLoop?   // window is oldest→newest, caller pre-trims to windowSize
}
```

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DreamuxTests/LoopDetectorTests.swift
import XCTest
@testable import Dreamux

final class LoopDetectorTests: XCTestCase {
    private func completion(_ signature: String, error: Bool) -> ToolCompletion {
        ToolCompletion(signature: signature, isError: error, at: nil)
    }

    func testSignatureDerivation() {
        XCTAssertEqual(LoopDetector.signature(tool: "Bash", summary: "swift test --filter X"), "Bash:swift")
        XCTAssertEqual(LoopDetector.signature(tool: "Bash", summary: nil), "Bash")
        XCTAssertEqual(LoopDetector.signature(tool: "Bash", summary: "   "), "Bash")
        XCTAssertEqual(LoopDetector.signature(tool: "Edit", summary: "/a/b.swift"), "Edit")
        XCTAssertEqual(LoopDetector.signature(tool: "Read", summary: "whatever"), "Read")
    }

    func testEditTestLoopDetectsDespiteInterleaving() {
        // edit → test(fail) → edit → test(fail) → edit → test(fail)
        let window = [
            completion("Edit", error: false), completion("Bash:swift", error: true),
            completion("Edit", error: false), completion("Bash:swift", error: true),
            completion("Edit", error: false), completion("Bash:swift", error: true),
        ]
        XCTAssertEqual(LoopDetector.detect(window: window), DetectedLoop(signature: "Bash:swift", count: 3))
    }

    func testTwoOccurrencesIsNotALoop() {
        let window = [
            completion("Bash:swift", error: true), completion("Edit", error: false),
            completion("Bash:swift", error: true),
        ]
        XCTAssertNil(LoopDetector.detect(window: window))
    }

    func testNeedsTwoErrorsAmongOccurrences() {
        // 3 occurrences but only the last errored — a command that mostly
        // works isn't a loop yet.
        let window = [
            completion("Bash:swift", error: false), completion("Bash:swift", error: false),
            completion("Bash:swift", error: true),
        ]
        XCTAssertNil(LoopDetector.detect(window: window))
    }

    func testClearedWhenNewestOccurrenceSucceeds() {
        // Failing streak then a pass: the loop resolved.
        let window = [
            completion("Bash:swift", error: true), completion("Bash:swift", error: true),
            completion("Bash:swift", error: true), completion("Bash:swift", error: false),
        ]
        XCTAssertNil(LoopDetector.detect(window: window))
    }

    func testCountIsOccurrencesInWindow() {
        let window = [
            completion("Bash:swift", error: true), completion("Bash:swift", error: true),
            completion("Bash:swift", error: true), completion("Bash:swift", error: true),
        ]
        XCTAssertEqual(LoopDetector.detect(window: window)?.count, 4)
    }

    func testMostOccurrencesWinsTieMostRecent() {
        // Two qualifying signatures: npm has 3, swift has 3; swift completed
        // more recently → swift wins the tie.
        let window = [
            completion("Bash:npm", error: true), completion("Bash:swift", error: true),
            completion("Bash:npm", error: true), completion("Bash:swift", error: true),
            completion("Bash:npm", error: true), completion("Bash:swift", error: true),
        ]
        XCTAssertEqual(LoopDetector.detect(window: window)?.signature, "Bash:swift")
        // And a clear majority beats recency:
        let window2 = window + [completion("Bash:npm", error: true)]
        XCTAssertEqual(LoopDetector.detect(window: window2)?.signature, "Bash:npm")
        XCTAssertEqual(LoopDetector.detect(window: window2)?.count, 4)
    }

    func testEmptyWindowIsNil() {
        XCTAssertNil(LoopDetector.detect(window: []))
    }
}
```

- [ ] **Step 2: Verify compile-fail** — `swift test --filter LoopDetectorTests`.

- [ ] **Step 3: Implement**

```swift
// Sources/Dreamux/Models/LoopDetector.swift
import Foundation

/// One finished tool call, reduced to what the loop heuristic needs.
struct ToolCompletion: Equatable, Sendable {
    let signature: String
    let isError: Bool
    let at: Date?
}

/// A detected repetition worth surfacing. A badge, never a judgment —
/// the UI must not claim the loop is stuck (spec).
struct DetectedLoop: Equatable, Sendable {
    let signature: String
    let count: Int
}

/// Conservative repetition heuristic over a lane's recent tool
/// completions. All thresholds are the spec's contract values.
enum LoopDetector {
    static let windowSize = 12

    /// Bash commands loop by their leading token ("Bash:swift"); every
    /// other tool loops by name alone — file paths vary per iteration,
    /// commands don't.
    static func signature(tool: String, summary: String?) -> String {
        guard tool == "Bash",
              let first = summary?.split(whereSeparator: \.isWhitespace).first,
              !first.isEmpty
        else { return tool }
        return "Bash:\(first)"
    }

    static func detect(window: [ToolCompletion]) -> DetectedLoop? {
        guard !window.isEmpty else { return nil }
        var counts: [String: (total: Int, errors: Int, lastIndex: Int, lastIsError: Bool)] = [:]
        for (index, completion) in window.enumerated() {
            var entry = counts[completion.signature] ?? (0, 0, 0, false)
            entry.total += 1
            if completion.isError { entry.errors += 1 }
            entry.lastIndex = index
            entry.lastIsError = completion.isError
            counts[completion.signature] = entry
        }
        let qualifying = counts.filter { $0.value.total >= 3 && $0.value.errors >= 2 && $0.value.lastIsError }
        guard let winner = qualifying.max(by: { lhs, rhs in
            if lhs.value.total != rhs.value.total { return lhs.value.total < rhs.value.total }
            return lhs.value.lastIndex < rhs.value.lastIndex
        }) else { return nil }
        return DetectedLoop(signature: winner.key, count: winner.value.total)
    }
}
```

- [ ] **Step 4: Verify green** (8 tests), then commit:

```bash
git add Sources/Dreamux/Models/LoopDetector.swift Tests/DreamuxTests/LoopDetectorTests.swift
git commit -m "Flows: conservative loop-detection heuristic"
```

---

### Task 2: FlowStore loop integration

**Files:**
- Modify: `Sources/Dreamux/Models/FlowStore.swift`
- Test: `Tests/DreamuxTests/FlowStoreLoopTests.swift`

**Interfaces:**
- Consumes: `LoopDetector`/`ToolCompletion`/`DetectedLoop` (Task 1); existing `apply(transcript:sessionID:)` paths.
- Produces: lanes carry at most one `.loop` self-edge (`from == to == "session"`, label = signature, iterations = count), live-updated; new private state swept with the other correlation dicts.

Semantics (the contract):
1. On `.toolStarted`: record `toolUseID → LoopDetector.signature(tool:summary:)` in a per-lane pending map (skip nothing here — agent ids get excluded at completion time).
2. On `.toolFinished`: if the id maps to an agent (existing `agentIDByToolUse` check) → do NOT track a completion (agents aren't commands). Else pop the pending signature (unknown id → ignore) and append `ToolCompletion(signature:isError:at:)` to the lane's ring (cap `LoopDetector.windowSize`, drop-oldest). Then run `LoopDetector.detect` on the ring and reconcile the lane's loop edge: nil → remove any `.loop` edge; DetectedLoop → replace/insert THE single `.loop` self-edge with new label/iterations. Reconcile only mutates when the edge actually changed (upsert equality guard does the rest).
3. Scheduled lanes (`kind == .scheduled`): skip all loop tracking.
4. `completeSessionNodes` additionally clears the two new maps (pending signatures + rings) for the lane AND removes its loop edge (a finished session isn't looping).
5. Aggregates unaffected by loop edges.

- [ ] **Step 1: Write the failing tests** — `FlowStoreLoopTests` (follow FlowStoreTranscriptTests idioms; construct transcript events directly):
1. `testFailingRepeatCreatesLoopEdge` — registry lane; 3× (toolStarted "Bash" summary "swift test …" → toolFinished isError true) → lane has exactly one edge with `kind == .loop`, `from == "session"`, `to == "session"`, `label == "Bash:swift"`, `iterations == 3`.
2. `testInterleavedEditsStillDetect` — edit/test alternation (Edit ok, Bash:swift fail ×3) → loop edge iterations 3.
3. `testLoopCountGrows` — 4th failing repeat → iterations 4 (same single edge, not a second edge).
4. `testPassClearsLoop` — after detection, a succeeding "Bash:swift" completion → no `.loop` edge remains.
5. `testAgentResultsExcluded` — meta-join an agent toolUseID, then 3 failing completions for that id → no loop edge.
6. `testScheduledLaneNeverLoops` — bg-kind lane + 3 failing repeats → no loop edge.
7. `testSweepClearsLoopStateAndEdge` — detection, then sessionStopped → loop edge gone; further completions for that lane don't resurrect it from stale ring state (ring cleared).
8. `testWindowEviction` — 3 failing "Bash:swift" then 12 unrelated successful completions → loop edge removed (aged out).

Write full test code for all 8.

- [ ] **Step 2: Verify compile-fail.**  - [ ] **Step 3: Implement per the semantics** (two new per-lane dicts: `pendingToolSignatures: [String: [String: String]]`, `toolCompletionRings: [String: [ToolCompletion]]`; a `reconcileLoopEdge(in:)` helper; sweep additions).  - [ ] **Step 4: Green (8/8 + FlowStoreTranscriptTests 10/10 untouched + full suite), commit:**

```bash
git add Sources/Dreamux/Models/FlowStore.swift Tests/DreamuxTests/FlowStoreLoopTests.swift
git commit -m "Flows: lanes carry live loop self-edges from tool-completion rings"
```

---

### Task 3: Loop rendering + flowsState edges

**Files:**
- Modify: `Sources/Dreamux/Views/FlowLaneView.swift`, `Sources/Dreamux/Views/FlowDetailView.swift`, `Sources/Dreamux/E2E/E2ECommands.swift`, `Scripts/e2e/PROTOCOL.md`

Spec: lane badge — when the lane has a `.loop` edge, the header (after the session chip) shows a compact badge `↺ <label> ×N` using the running/orange treatment (`arrow.2.circlepath` icon + caption text, capsule fill like the existing chips; pulse NOT applied — the count updating is the signal). Detail view — Canvas: an edge with `from == to` renders as a dashed circular arc (≈270°) anchored at the node's trailing edge (radius ~18), with a small `↺ ×N` label beside it; non-self `.loop` edges (future) stay dashed straight lines. flowsState: each lane dict gains `"edges": [{from, to, kind, label?, iterations?}]` (rawValue kinds; omit-if-nil optionals) — document in PROTOCOL.md.

- [ ] **Step 1: flowsState edges + PROTOCOL** (mechanical; mirror the nodes mapping).
- [ ] **Step 2: Lane badge + detail arc** (build-gated; e2e Task 7 screenshots them).
- [ ] **Step 3: `swift build && swift test` green; commit:**

```bash
git add Sources/Dreamux/Views/FlowLaneView.swift Sources/Dreamux/Views/FlowDetailView.swift Sources/Dreamux/E2E/E2ECommands.swift Scripts/e2e/PROTOCOL.md
git commit -m "Flows: loop badges on lanes, dashed self-loops in zoom, edges in flowsState"
```

---

### Task 4: Tailer-pool hygiene (the big rider)

**Files:**
- Modify: `Sources/Dreamux/Models/FlowTailerPool.swift`
- Test: `Tests/DreamuxTests/FlowTailerPoolTests.swift`

Four items, one reviewer gate:
1. **Mtime-gated cached meta parsing, off main.** `scanSubagentsDir` currently JSON-parses every meta inline on the main queue per dir event (O(N²) bursts; 219-meta real dir). Fix: keep a per-session `metaCache: [String: (mtime: Date, meta: SubagentMeta)]`; on scan, `stat` each meta file (cheap) and re-parse ONLY new/changed files — but STILL call `onMeta` for every cache entry on every scan (unconditional re-emission is the join-resweep design; keep the comment). Move the stat+parse work off the main queue (utility queue, then one `Task { @MainActor }` hop delivering the full emission batch in order). The dir-event handler itself just schedules the scan.
2. **Dynamic ranking → re-promotion live.** Refresh `agentFileModDates[agentID]` from each scan's stat pass (same stat as item 1 — no extra IO). This makes `enforceAgentTailerCap`'s re-rank real: growing files rise, stale ones fall. The existing re-promotion `resume()` branch (everStartedAgentTailerIDs) now becomes reachable — verify offset preservation end-to-end.
3. **SessionState deinit** cancels `subagentsWatcher` (fd leak at project-window close); also cross-reference the accepted post-stop race comment to the watcher guard (one sentence).
4. **Tests:** (a) two-scan demote-stop — 24 live, 4 newer files arrive, rescan demotes a genuinely-RUNNING tailer; append to the demoted file → no delivery (inverted 0.5s); (b) re-promotion resume — demoted tailer's file gets NEW appends (mtime rises), rescan re-promotes it → appended lines arrive FROM THE STORED OFFSET (assert the gap content written while demoted is delivered — that's resume(), not EOF-seek); (c) mtime-gate — scan twice with no changes → parse count doesn't grow (add an internal `metaParseCount` seam) while onMeta emission count DOES grow (re-emission preserved); (d) correct the cap test's overclaiming discrimination comment (from the G3 confirm). Timing suites run TWICE.

- [ ] Steps: tests-first for (a)–(c), implement, both-green ×2, full suite, commit:

```bash
git add Sources/Dreamux/Models/FlowTailerPool.swift Tests/DreamuxTests/FlowTailerPoolTests.swift
git commit -m "Flows: cached off-main meta scans, dynamic tailer ranking, watcher deinit"
```

---

### Task 5: Tailer cap-overflow accounting

**Files:**
- Modify: `Sources/Dreamux/Models/ClaudeTranscriptTailer.swift`
- Test: `Tests/DreamuxTests/ClaudeTranscriptTailerTests.swift`

`readAvailable`'s 1 MB partial-buffer cap currently drops the whole buffer AFTER appending the chunk — discarding any complete lines inside it, uncounted. Fix: before the cap check, split the buffer and deliver all complete lines; only the trailing newline-less remainder counts against the cap; when over, drop the remainder and report the drop to a new optional `onDroppedBytes: ((Int) -> Void)?` callback (nil default keeps the public contract; FlowTailerPool wires it into `noteSkippedLines(1, ...)` — one skipped "line" per drop event, documented as the coarse mapping). Test: a >1 MB single line followed by normal lines on the same wake → normal lines delivered, drop callback fired once, subsequent appends still delivered (buffer reset clean). Run twice.

```bash
git add Sources/Dreamux/Models/ClaudeTranscriptTailer.swift Sources/Dreamux/Models/FlowTailerPool.swift Tests/DreamuxTests/ClaudeTranscriptTailerTests.swift
git commit -m "Flows: cap overflow keeps complete lines and counts the drop"
```

(FlowTailerPool.swift joins the named files for the one-line wiring.)

---

### Task 6: Store/view polish riders

**Files:**
- Modify: `Sources/Dreamux/Models/FlowStore.swift` (lane(for:) dedup), `Sources/Dreamux/Models/FlowLayoutEngine.swift` (comment only), `Sources/Dreamux/Views/FlowsOverviewView.swift` (stale-zoom guard)
- Test: existing suites must stay green; one new test for the zoom guard is NOT possible (view-state) — build-gated.

1. Dedup the four fetch-or-make lane boilerplate copies in FlowStore into one `private func fetchOrMakeLane(sessionID: String, cwd: String?, at: Date?) -> Flow` (behavior-identical; all suites green unmodified proves it).
2. FlowLayoutEngine: correct the "Position columns symmetrically around center" comment to state reality (global-width centering; single-node ranks sit at the widest rank's left column) — comment only, tests pin behavior.
3. FlowsOverviewView: when the zoomed lane id no longer exists in the board, clear the binding (`onChange(of: board-membership)` or equivalent minimal check in body) so a later same-id lane can't resurface a stale detail view.

```bash
git add Sources/Dreamux/Models/FlowStore.swift Sources/Dreamux/Models/FlowLayoutEngine.swift Sources/Dreamux/Views/FlowsOverviewView.swift
git commit -m "Flows: lane fetch dedup, truthful layout comment, stale-zoom guard"
```

---

### Task 7: e2e loop scenario

**Files:**
- Modify: `Scripts/e2e/driver.py`, `Scripts/e2e/PROTOCOL.md` (only if response fields change beyond Task 3's doc)

Extend `scenario_flows` after the zoom section: append to the synthetic transcript ≥3 pairs of (assistant tool_use Bash "swift test --filter Snip" / user tool_result is_error true) with fresh toolu ids; wait via flowsState for a lane edge `kind == "loop"` with `iterations >= 3` and `label == "Bash:swift"`; screenshot `flows-loop-overview` (lane badge visible); `zoomFlow` the lane, screenshot `flows-loop-zoom` (dashed self-arc + ×N), `zoomFlow` null. Then one success pair (is_error false) → wait for the loop edge to disappear from flowsState (clear semantics verified end-to-end). READ all new screenshots; a passing assertion with an invisible badge is a failure.

```bash
git add Scripts/e2e/driver.py Scripts/e2e/PROTOCOL.md
git commit -m "Flows: e2e failing-test loop appears, renders, and clears"
```

---

### Task 8: Live validation + opportunistic real-data checks

**Files:**
- Modify: `Tests/DreamuxTests/LiveShapeValidationTests.swift` (add a loop-detector pass), `Scripts/e2e/validate-flows-live.sh` (unchanged unless needed)

1. Extend the live-shape test: for each real transcript, feed its tool completions through the FlowStore-equivalent ring simulation (pure: signatures via LoopDetector, rings of 12) and PRINT counts only — transcripts scanned, total completions, loops that WOULD have been detected (signature counts only, no content). No assertion thresholds on loops (informational); existing skip-ratio/meta assertions unchanged.
2. Run `Scripts/e2e/validate-flows-live.sh`; paste the summary in the report.
3. Opportunistic checks (read-only): (a) `~/Library/Logs/Dreamux-hook.log` — if it now exists, grep `flow_in` and report whether TaskCreated payloads carry task_id/subject (counts/keys only); (b) `sqlite3 ~/Library/Application\ Support/*/signals.db "select kind, count(*) from signals where kind like 'agent.%' or kind like 'session.%' or kind like 'task.%' group by kind;"` — the app relaunched with the new shim at 18:16 today; report whether real flow signals have appeared. Record both outcomes verbatim in the report for the ledger.

```bash
git add Tests/DreamuxTests/LiveShapeValidationTests.swift
git commit -m "Flows: live validation gains an informational loop pass"
```

---

## Deferred (explicitly NOT this plan)

- Gate action cards (Group 5). Team-session `.failed`/loop inertness (documented limitation). Non-self `.loop` edges between distinct nodes (needs per-tool nodes — future). Stop-tailing-non-growing-files eviction policy (the dynamic ranking gets most of the value; revisit if fd pressure reappears).
