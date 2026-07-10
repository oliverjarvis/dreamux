# Claude Chat Face Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every terminal tab running interactive Claude Code a second, native **Chat** face — the live conversation rendered from the session transcript, with a composer, question-answer buttons, and permission banners that inject keystrokes back through the tab's own PTY.

**Architecture:** Three channels. *Content:* a `TranscriptAccumulator` + `LiveConversation` tail the session's `~/.claude/projects/<slug>/<uuid>.jsonl`. *State:* `dreamux-hook` gains a **control OSC** channel (`OSC 777;dreamux;<verb>;<base64url-json>` on `/dev/tty`) so `SessionStart`/`SessionEnd`/`Notification`/`Stop` events arrive pre-correlated inside the tab's own PTY byte stream, where a typed `extractActivitySignals` routes them to a per-tab `ClaudeSessionBinding` state machine (registry file `~/.claude/sessions/<pid>.json` as liveness backstop). *Input:* clicks and composer text become keystrokes via `PromptKeystrokeRecipes` → `PTYShellSession.send` — always visible on the Terminal face.

**Tech Stack:** Swift 6 / SwiftPM, SwiftUI + MarkdownUI, DispatchSource file watchers, POSIX shell + Python 3 (`Tools/claude`, `Tools/dreamux-hook`), XCTest, e2e harness (`Scripts/e2e/`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-10-claude-chat-face-design.md` (read it first).
- **Never write under `~/.claude`**; never read `ide/<pid>.lock` or `daemon/control.key`. Hook additions must be `async`/fail-silent — a hook must never break or slow the user's claude session (existing `dreamux-hook` discipline).
- **Never blind-type**: every injected keystroke path is gated on `ClaudeSessionBinding` state; unknown dialog shapes degrade to a "Respond in terminal" banner. The permission-recipe table ships **empty** (banner + flip only) — structure in place, entries added only after real-payload verification.
- `Stop` fires at the end of EVERY assistant turn; `SessionEnd` is the true once-per-session terminal event. Do not conflate (cost a merge-blocking finding once already).
- Swift 6: stores/bindings are `@MainActor @Observable`; pure helpers are `nonisolated` statics on enums/structs, tested without actors.
- Design scale (CLAUDE.md): message text 14–15pt, hover wash `Color.primary.opacity(0.04)`/selected `0.08` on `RoundedRectangle(cornerRadius: 8)`, header controls are outlined pills (cornerRadius 8, `strokeBorder` `.secondary.opacity(0.3)`, `.primary.opacity(0.04)` fill, 1pt hairline segment divider), MarkdownUI page background cleared, no `Divider()` under headers. Buttons use `SoftButtonStyle`.
- Degrade, never crash: malformed JSONL, missing transcript, missed hooks, vanished registry files all render honest fallback states.
- Stage only named files when committing; re-verify HEAD before each commit (parallel sessions touch main).
- Full `swift build` + `swift test` green before every commit.
- House test style: pure logic gets XCTest units; SwiftUI views are anchored sketches, build-gated, verified by e2e screenshots — no unit tests for views.

## Adaptation ground rules

Anchors verified at HEAD `a789059` (2026-07-10). If a line number has drifted, search for the quoted symbol.

- `Tools/dreamux-hook` — `emit()` (~line 60: OSC 9 to `/dev/tty`, stdout fallback), `read_stdin_json()`, `emit_signal()`, `flow_handler()` (SessionEnd → `session.stopped`), `stop_handler()` (transcript-polling notification), `notify_handler()` (tail: `emit_signal("session.notification", …)` then `emit(message)`), `main()` dispatch at the bottom. `log()` gated on `DREAMUX_HOOK_DEBUG=1` → `~/Library/Logs/Dreamux-hook.log`.
- `Tools/claude` — shim; hooks JSON assembly near the end: `SYNC_STOP`/`SYNC_NOTIFY`/`FLOW_MATCHED`/`FLOW_PLAIN` vars then `SETTINGS_JSON` concatenation and `exec "$REAL_CLAUDE" --settings "$SETTINGS_JSON" "$@"`. `HOOK_CMD` is the escaped-quote hook path.
- `Sources/Dreamux/Shell/PTYShellSession.swift` — `extractActivitySignals(_:) -> [String?]` at :333 (static, pure, already handles OSC 9 flavours + OSC 777;notify + bare BEL, `splitSemicolons` helper below it); call site in `startReader` at :257–260 (`for message in signals { activityHandler?(message) }`); `init(cwd:extraEnv:onActivity:)` at :63; `send(_:)` at :229.
- `Sources/Dreamux/Models/TabSession.swift` — `@MainActor @Observable final class` :8; `init(cwd:onActivity:)` :23–28 constructs `PTYShellSession(cwd: cwd, onActivity: onActivity)`; `send(_:)` :158; `startIfNeeded()` :145.
- `Sources/Dreamux/Models/WorkspaceSession.swift:257-264` — the only `TabSession(cwd:onActivity:)` construction (closure hops to `handleActivity(tabId:message:)`); `openFileTab(at:revealingLine:)` :464; `handleActivity` :521–548 (bare-BEL vs message semantics — keep identical).
- `Sources/Dreamux/Views/Viewers/TranscriptView.swift` — `TranscriptItem` :87–100, `TranscriptParser` enum :106–195 (move both), `TranscriptRow`/`MessageBlock`/`CollapsibleBlock` :199–307 (all `private`; move + de-private in Task 8). `TranscriptView.load()` :65 calls `TranscriptParser.parse`.
- `Tests/DreamuxTests/TranscriptParserTests.swift` — house test style for the parser; Task 4 updates its `toolUse` pattern-matches (the case gains an `id`), everything else keeps passing unchanged.
- `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift:82-133` — `TabContentView`; the terminal branch is `:107-118` (`let isSelectedTab…` + `HostedTerminalView(session:dropTargetEnabled:)` + `.onAppear { tabSession.startIfNeeded() }`).
- `Sources/Dreamux/Views/SoftButtonStyle.swift` — shared button style.
- `Sources/Dreamux/E2E/E2ECommands.swift:52-120` — command dispatch (`case "…"`); `Scripts/e2e/driver.py`, `Scripts/e2e/PROTOCOL.md`, `Scripts/e2e/run-e2e.sh`. Screenshots are contentView-only.
- Registry file shape (verified July 2026, claude 2.1.201): `~/.claude/sessions/<pid>.json` = `{sessionId, cwd, status: idle|busy|waiting, name, kind, updatedAt}`. Transcript: one JSONL line per content block; assistant `tool_use` blocks carry `id`+`name`+`input`; user `tool_result` blocks carry `tool_use_id`.
- `AskUserQuestion` tool input shape: `{"questions":[{"question":…, "header":…, "multiSelect":bool, "options":[{"label":…, "description":…}]}]}`.
- Verification caveat: shell steps below run the hook **without a tty** (agent Bash has no controlling terminal), so `emit`/`control_emit` fall back to stdout — that's what the asserts read. In a real tab they write to `/dev/tty`.

---

## Group 1 — Control-OSC protocol (hook scripts)

### Task 1: `dreamux-hook` control channel

**Files:**
- Modify: `Tools/dreamux-hook`

**Interfaces:**
- Produces: control OSC `ESC ] 777 ; dreamux ; <verb> ; <base64url(JSON)> BEL` on `/dev/tty` (stdout fallback), verbs `session-start`, `session-end`, `notify`, `stop`. Payloads: session-start `{session_id, transcript_path, cwd, source, claude_pid}`; session-end `{session_id}`; notify `{message, session_id, cwd}`; stop `{session_id}`. Swift side (Task 3) decodes these.

- [ ] **Step 1: Add `control_emit` below `emit()`**

```python
def control_emit(verb: str, payload: dict) -> None:
    """Emit a Dreamux control OSC: a structured event Dreamux's PTY
    parser routes to the owning tab (session binding, chat-face state).
    Same transport rationale as emit(); base64url keeps the body free
    of semicolons and terminators so the Swift-side splitter can't
    clip it. OSC 777 subcommand `dreamux` — unknown to terminals,
    invisible if it ever leaks to a real one."""
    import base64

    body = base64.urlsafe_b64encode(
        json.dumps(payload, separators=(",", ":")).encode("utf-8")
    ).decode("ascii")
    seq = f"\033]777;dreamux;{verb};{body}\a"
    try:
        with open("/dev/tty", "w") as tty:
            tty.write(seq)
            tty.flush()
            log("control_emit", channel="/dev/tty", verb=verb)
            return
    except OSError as exc:
        log("control_emit_tty_fail", verb=verb, error=str(exc))
    sys.stdout.write(seq)
    sys.stdout.flush()
    log("control_emit", channel="stdout", verb=verb)
```

- [ ] **Step 2: Add `session_start_handler` next to the other handlers**

```python
def session_start_handler() -> None:
    """`dreamux-hook session-start` — announce a new/resumed/cleared
    session to the owning Dreamux tab. claude_pid = our parent (the
    hook runs as claude's child), which names the session's registry
    file ~/.claude/sessions/<pid>.json."""
    payload = read_stdin_json()
    if not payload:
        log("session_start_skip", reason="no_stdin_json")
        return
    control_emit("session-start", {
        "session_id": payload.get("session_id") or "",
        "transcript_path": payload.get("transcript_path") or "",
        "cwd": payload.get("cwd") or "",
        "source": payload.get("source") or "",
        "claude_pid": os.getppid(),
    })
```

- [ ] **Step 3: Dual-emit from the three existing handlers**

In `flow_handler()`, after the existing `emit_signal(kind, payload)` line:

```python
    if event == "SessionEnd":
        control_emit("session-end", {"session_id": payload.get("session_id") or ""})
```

In `stop_handler()`, immediately after the `if payload is None:` guard (BEFORE the transcript polling — the control event must fire on every turn end, including interrupts the notification path deliberately skips):

```python
    control_emit("stop", {"session_id": payload.get("session_id") or ""})
```

In `notify_handler()`, right before the final `emit(message)` (keep the existing `emit_signal` and `emit` untouched):

```python
    control_emit("notify", {
        "message": message or "",
        "session_id": (payload or {}).get("session_id") or "",
        "cwd": (payload or {}).get("cwd") or "",
    })
```

(Adapt to `notify_handler`'s local variable names — it already resolves `payload` from `read_stdin_json()` and `message` before emitting.)

- [ ] **Step 4: Register the subcommand in `main()`**

```python
    elif cmd == "session-start":
        session_start_handler()
```

(before the generic `elif cmd:` free-text fallback).

- [ ] **Step 5: Verify by piping (no tty → stdout fallback)**

```bash
echo '{"session_id":"s-1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp","source":"startup"}' \
  | Tools/dreamux-hook session-start | python3 -c '
import sys, re, base64, json
out = sys.stdin.buffer.read().decode()
m = re.search(r"\x1b\]777;dreamux;session-start;([A-Za-z0-9_=-]+)\x07", out)
assert m, repr(out)
p = json.loads(base64.urlsafe_b64decode(m.group(1)))
assert p["session_id"] == "s-1" and p["transcript_path"] == "/tmp/t.jsonl"
assert isinstance(p["claude_pid"], int) and p["claude_pid"] > 0
print("session-start OK", p)'
```

Expected: `session-start OK {...}`. Same pattern for the dual-emits:

```bash
echo '{"hook_event_name":"SessionEnd","session_id":"s-1","cwd":"/tmp"}' \
  | Tools/dreamux-hook flow | grep -c $'\x1b]777;dreamux;session-end;'
echo '{"session_id":"s-1"}' | Tools/dreamux-hook stop | grep -c $'\x1b]777;dreamux;stop;'
echo '{"session_id":"s-1","message":"Claude needs permission to use Bash"}' \
  | Tools/dreamux-hook notify | grep -c $'\x1b]777;dreamux;notify;'
```

Expected: `1` each. (`flow` also tries the signal socket — absent env → silent no-op, fine.)

- [ ] **Step 6: Commit**

```bash
git add Tools/dreamux-hook
git commit -m "dreamux-hook: control-OSC channel (session-start/end, notify, stop)"
```

### Task 2: Shim injects `SessionStart`

**Files:**
- Modify: `Tools/claude`

**Interfaces:**
- Produces: injected `--settings` JSON gains `"SessionStart"` entry invoking `dreamux-hook session-start` (async).

- [ ] **Step 1: Add the hook entry**

Next to the existing `FLOW_PLAIN` definition:

```sh
SESSION_START='{"hooks":[{"type":"command","command":'"$HOOK_CMD"' session-start","async":true}]}'
```

And in the `SETTINGS_JSON` assembly (before the `"SessionEnd"` line):

```sh
SETTINGS_JSON="$SETTINGS_JSON"'"SessionStart":['"$SESSION_START"'],'
```

Extend the comment block above the assembly with one line: `# SessionStart: chat-face session binding (dreamux-hook session-start → control OSC).`

- [ ] **Step 2: Verify with a fake downstream claude**

```bash
tmp=$(mktemp -d) && printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$tmp/claude" && chmod +x "$tmp/claude"
PATH="$tmp:$PATH" Tools/claude | python3 -c '
import sys, json
args = sys.stdin.read().splitlines()
settings = json.loads(args[args.index("--settings") + 1])
h = settings["hooks"]["SessionStart"][0]["hooks"][0]
assert h["async"] is True and h["command"].endswith(" session-start"), h
assert set(settings["hooks"]) >= {"Stop","Notification","SessionStart","SessionEnd"}
print("shim OK")'
```

Expected: `shim OK`.

- [ ] **Step 3: Commit**

```bash
git add Tools/claude
git commit -m "claude shim: inject SessionStart hook for chat-face binding"
```

---

## Group 2 — Swift read path

### Task 3: Typed `ActivitySignal` extraction

**Files:**
- Modify: `Sources/Dreamux/Shell/PTYShellSession.swift`
- Modify: `Sources/Dreamux/Models/TabSession.swift` (pass-through param only)
- Test: `Tests/DreamuxTests/ActivitySignalTests.swift` (create)

**Interfaces:**
- Produces: `enum ActivitySignal: Equatable, Sendable { case ping; case notification(String); case control(verb: String, json: Data) }` (top level, in PTYShellSession.swift); `PTYShellSession.extractActivitySignals(_: ArraySlice<UInt8>) -> [ActivitySignal]`; `PTYShellSession.init(cwd:extraEnv:onActivity:onControl:)` where `onControl: (@Sendable (String, Data) -> Void)? = nil`; `TabSession.init(cwd:onActivity:onControl:)` forwarding it. Task 6 consumes `onControl`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Dreamux

final class ActivitySignalTests: XCTestCase {
    private func signals(_ s: String) -> [ActivitySignal] {
        let bytes = Array(s.utf8)
        return PTYShellSession.extractActivitySignals(bytes[...])
    }

    func testExistingFlavoursKeepTheirMeaning() {
        XCTAssertEqual(signals("\u{07}"), [.ping])
        XCTAssertEqual(signals("\u{1B}]9;hello world\u{07}"), [.notification("hello world")])
        XCTAssertEqual(signals("\u{1B}]777;notify;Title;Body\u{07}"), [.notification("Title: Body")])
        // ConEmu numeric subcommand still ignored
        XCTAssertEqual(signals("\u{1B}]9;4;1;50\u{07}"), [])
    }

    func testControlSignalDecodes() {
        // base64url of {"session_id":"s-1"} — no padding chars needed here,
        // but the decoder must tolerate them (see next test).
        let b64 = Data("{\"session_id\":\"s-1\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let got = signals("\u{1B}]777;dreamux;session-start;\(b64)\u{07}")
        guard case .control(let verb, let json)? = got.first else {
            return XCTFail("expected control, got \(got)")
        }
        XCTAssertEqual(verb, "session-start")
        let dict = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertEqual(dict?["session_id"] as? String, "s-1")
    }

    func testControlSurvivesInterleavedOutputAndBadPayload() {
        let b64 = Data("{}".utf8).base64EncodedString()
        let mixed = "plain text\u{1B}]777;dreamux;stop;\(b64)\u{07}more\u{07}"
        XCTAssertEqual(signals(mixed), [.control(verb: "stop", json: Data("{}".utf8)), .ping])
        // Garbage payload → dropped, no crash, following signals intact.
        XCTAssertEqual(signals("\u{1B}]777;dreamux;stop;!!!\u{07}\u{07}"), [.ping])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ActivitySignalTests 2>&1 | tail -5`
Expected: compile failure — `ActivitySignal` not defined.

- [ ] **Step 3: Implement**

In `PTYShellSession.swift`, above the class:

```swift
/// One attention/control event extracted from the PTY byte stream.
enum ActivitySignal: Equatable, Sendable {
    /// Bare BEL — generic ping, no payload.
    case ping
    /// OSC 9 / OSC 777;notify — human-readable notification body.
    case notification(String)
    /// OSC 777;dreamux;<verb>;<base64url-json> — structured event from
    /// dreamux-hook, arriving inside the session's own PTY so it is
    /// already correlated to this tab (session binding, chat state).
    case control(verb: String, json: Data)
}
```

Rewrite `extractActivitySignals` to return `[ActivitySignal]`: same walk, `signals.append(.notification(body))` where it appended `body`, `.ping` where it appended `nil`, and a new branch **before** the `777;notify` one:

```swift
                } else if parts.first == "777", parts.count >= 4, parts[1] == "dreamux" {
                    if let json = decodeBase64URL(parts[3]) {
                        signals.append(.control(verb: parts[2], json: json))
                    }
                    // undecodable payload: drop silently — a control
                    // event we can't parse must never become a banner.
                }
```

with the helper:

```swift
    private static func decodeBase64URL(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }
```

Init gains `onControl: (@Sendable (String, Data) -> Void)? = nil` stored as `private let onControl`. The `startReader` loop becomes:

```swift
                let signals = Self.extractActivitySignals(buffer.prefix(n))
                for signal in signals {
                    switch signal {
                    case .ping: activityHandler?(nil)
                    case .notification(let message): activityHandler?(message)
                    case .control(let verb, let json): controlHandler?(verb, json)
                    }
                }
```

(capture `let controlHandler = onControl` beside `activityHandler`). `TabSession.init` gains `onControl: (@Sendable (String, Data) -> Void)? = nil` forwarded to `PTYShellSession` — `WorkspaceSession` untouched (defaulted).

- [ ] **Step 4: Run tests**

Run: `swift test --filter ActivitySignalTests && swift test --filter TranscriptParserTests`
Expected: PASS (and full `swift build` clean).

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Shell/PTYShellSession.swift Sources/Dreamux/Models/TabSession.swift Tests/DreamuxTests/ActivitySignalTests.swift
git commit -m "PTY: typed ActivitySignal extraction with dreamux control OSCs"
```

### Task 4: Parser move + `TranscriptAccumulator`

**Files:**
- Create: `Sources/Dreamux/Models/TranscriptParser.swift` (moved code)
- Create: `Sources/Dreamux/Models/TranscriptAccumulator.swift`
- Modify: `Sources/Dreamux/Views/Viewers/TranscriptView.swift` (delete moved code)
- Test: `Tests/DreamuxTests/TranscriptAccumulatorTests.swift` (create)

**Interfaces:**
- Produces: `TranscriptParser.parseLine(_ line: String) -> [TranscriptItem]` (new, refactored out of `parse`); `TranscriptItem.Kind.toolUse` becomes `case toolUse(id: String?, name: String, input: String)` (the id is the subagent-join key, Task 8); `final class TranscriptAccumulator` with `items: [TranscriptItem]`, `@discardableResult func feed(_ data: Data) -> [TranscriptItem]`, `var pendingQuestion: PendingQuestion?`; `struct PendingQuestion: Equatable, Sendable { let toolUseID: String; let questions: [Question] }` with `Question { text, multiSelect, options: [Option{label, description}] }`. Tasks 5/7/8 consume these names exactly.

- [ ] **Step 1: Move `TranscriptItem` + `TranscriptParser` verbatim** from `TranscriptView.swift:87-195` into `Sources/Dreamux/Models/TranscriptParser.swift` (imports: `Foundation`), with ONE shape change: `case toolUse(name: String, input: String)` becomes `case toolUse(id: String?, name: String, input: String)`, populated in `appendMessage` via `block["id"] as? String`. Update the two existing pattern-matches — `TranscriptRow` (`case .toolUse(_, let name, let input)`) and `TranscriptParserTests` (same) — no behavior change. Inside `parse`, extract the per-line body into:

```swift
    /// Parse one JSONL line. Exposed for incremental feeding
    /// (TranscriptAccumulator); `parse` remains the whole-file path.
    static func parseLine(_ line: String) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        let data = Data(line.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return [TranscriptItem(kind: .raw(line))]
        }
        switch dict["type"] as? String {
        case "user": appendMessage(dict["message"] as? [String: Any], isUser: true, into: &items)
        case "assistant": appendMessage(dict["message"] as? [String: Any], isUser: false, into: &items)
        case "summary":
            if let summary = dict["summary"] as? String, !summary.isEmpty {
                items.append(TranscriptItem(kind: .summary(summary)))
            }
        case let type? where skipTypes.contains(type): break
        default: items.append(TranscriptItem(kind: .raw(pretty(dict) ?? line)))
        }
        return items
    }

    static func parse(_ text: String) -> [TranscriptItem] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .flatMap { parseLine(String($0)) }
    }
```

- [ ] **Step 2: Run existing parser tests** — `swift test --filter TranscriptParserTests` — Expected: PASS unchanged.

- [ ] **Step 3: Write failing accumulator tests**

```swift
import XCTest
@testable import Dreamux

final class TranscriptAccumulatorTests: XCTestCase {
    private let fixture = """
    {"type":"user","message":{"role":"user","content":"hello"}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi!"}]}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{"questions":[{"question":"Pick one?","header":"Pick","multiSelect":false,"options":[{"label":"A","description":"first"},{"label":"B","description":"second"}]}]}}]}}
    {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"q1","content":"A"}]}}

    """

    func testChunkedFeedMatchesWholeParseAndBuffersPartialLines() {
        let whole = TranscriptParser.parse(fixture)
        let acc = TranscriptAccumulator()
        let bytes = Array(fixture.utf8)
        // Split at awkward offsets: mid-line, mid-JSON.
        for chunk in [bytes[0..<50], bytes[50..<51], bytes[51..<200], bytes[200...]] {
            acc.feed(Data(chunk))
        }
        XCTAssertEqual(acc.items.count, whole.count)
        // No trailing partial: last line ended with \n.
        XCTAssertNil(acc.pendingQuestion)
    }

    func testPendingQuestionAppearsThenClears() {
        let lines = fixture.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let acc = TranscriptAccumulator()
        acc.feed(Data((lines[0] + "\n" + lines[1] + "\n").utf8))
        XCTAssertNil(acc.pendingQuestion)
        acc.feed(Data((lines[2] + "\n").utf8))
        let q = acc.pendingQuestion
        XCTAssertEqual(q?.toolUseID, "q1")
        XCTAssertEqual(q?.questions.first?.text, "Pick one?")
        XCTAssertEqual(q?.questions.first?.multiSelect, false)
        XCTAssertEqual(q?.questions.first?.options.map(\.label), ["A", "B"])
        acc.feed(Data((lines[3] + "\n").utf8))
        XCTAssertNil(acc.pendingQuestion)
    }

    func testFeedReturnsOnlyNewItems() {
        let acc = TranscriptAccumulator()
        let first = acc.feed(Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"a\"}}\n".utf8))
        XCTAssertEqual(first.count, 1)
        let none = acc.feed(Data("{\"type\":\"user\",\"message\":".utf8)) // partial
        XCTAssertTrue(none.isEmpty)
        let second = acc.feed(Data("{\"role\":\"user\",\"content\":\"b\"}}\n".utf8))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(acc.items.count, 2)
    }
}
```

- [ ] **Step 4: Run to verify failure** — `swift test --filter TranscriptAccumulatorTests 2>&1 | tail -5` — Expected: compile failure (`TranscriptAccumulator` undefined).

- [ ] **Step 5: Implement `TranscriptAccumulator`**

```swift
import Foundation

/// Incremental reader state for a live transcript: feed appended bytes,
/// get the newly parsed items. Buffers a partial trailing line between
/// feeds (splits on the newline byte, so multi-byte UTF-8 inside a line
/// is never torn) and tracks AskUserQuestion tool_use/tool_result
/// pairing — an unanswered one means a question dialog is on screen.
final class TranscriptAccumulator {
    private(set) var items: [TranscriptItem] = []
    private var partial = Data()
    private var openQuestions: [PendingQuestion] = []

    struct PendingQuestion: Equatable, Sendable {
        let toolUseID: String
        let questions: [Question]
        struct Question: Equatable, Sendable {
            let text: String
            let multiSelect: Bool
            let options: [Option]
            struct Option: Equatable, Sendable {
                let label: String
                let description: String
            }
        }
    }

    var pendingQuestion: PendingQuestion? { openQuestions.last }

    @discardableResult
    func feed(_ data: Data) -> [TranscriptItem] {
        partial.append(data)
        guard let lastNewline = partial.lastIndex(of: 0x0A) else { return [] }
        let complete = String(decoding: partial[partial.startIndex...lastNewline], as: UTF8.self)
        partial = Data(partial[partial.index(after: lastNewline)...])
        var newItems: [TranscriptItem] = []
        for line in complete.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)
            trackQuestions(line)
            newItems.append(contentsOf: TranscriptParser.parseLine(line))
        }
        items.append(contentsOf: newItems)
        return newItems
    }

    private func trackQuestions(_ line: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let dict = object as? [String: Any],
              let type = dict["type"] as? String,
              let message = dict["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks {
            switch block["type"] as? String {
            case "tool_use" where type == "assistant":
                guard block["name"] as? String == "AskUserQuestion",
                      let id = block["id"] as? String,
                      let pending = Self.pendingQuestion(from: block["input"], toolUseID: id)
                else { continue }
                openQuestions.append(pending)
            case "tool_result" where type == "user":
                if let id = block["tool_use_id"] as? String {
                    openQuestions.removeAll { $0.toolUseID == id }
                }
            default: break
            }
        }
    }

    private static func pendingQuestion(from input: Any?, toolUseID: String) -> PendingQuestion? {
        guard let input = input as? [String: Any],
              let rawQuestions = input["questions"] as? [[String: Any]] else { return nil }
        let questions = rawQuestions.compactMap { raw -> PendingQuestion.Question? in
            guard let text = raw["question"] as? String else { return nil }
            let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { opt -> PendingQuestion.Question.Option? in
                guard let label = opt["label"] as? String else { return nil }
                return .init(label: label, description: opt["description"] as? String ?? "")
            }
            return .init(text: text, multiSelect: raw["multiSelect"] as? Bool ?? false, options: options)
        }
        guard !questions.isEmpty else { return nil }
        return PendingQuestion(toolUseID: toolUseID, questions: questions)
    }
}
```

- [ ] **Step 6: Run tests** — `swift test --filter 'TranscriptAccumulatorTests|TranscriptParserTests'` — Expected: PASS. Then `swift build` — clean (TranscriptView still compiles against the moved parser).

- [ ] **Step 7: Commit**

```bash
git add Sources/Dreamux/Models/TranscriptParser.swift Sources/Dreamux/Models/TranscriptAccumulator.swift Sources/Dreamux/Views/Viewers/TranscriptView.swift Tests/DreamuxTests/TranscriptAccumulatorTests.swift
git commit -m "Transcripts: parser to Models + incremental TranscriptAccumulator"
```

### Task 5: `LiveConversation` tailer

**Files:**
- Create: `Sources/Dreamux/Models/LiveConversation.swift`
- Test: `Tests/DreamuxTests/LiveConversationTests.swift` (create)

**Interfaces:**
- Consumes: `TranscriptAccumulator` (Task 4).
- Produces: `@MainActor @Observable final class LiveConversation` — `init(url: URL)`, `items: [TranscriptItem]`, `pendingQuestion: TranscriptAccumulator.PendingQuestion?`, `fileFound: Bool`, `func stop()`. Task 6 owns one per binding; Task 8 renders it.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Dreamux

final class LiveConversationTests: XCTestCase {
    @MainActor
    func testParsesExistingContentThenTailsAppends() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("t.jsonl")
        let line1 = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"one\"}}\n"
        let line2 = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"two\"}]}}\n"
        try line1.write(to: url, atomically: true, encoding: .utf8)

        let conv = LiveConversation(url: url)
        defer { conv.stop() }
        try await Self.eventually { conv.items.count == 1 }

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line2.utf8))
        try handle.close()
        try await Self.eventually { conv.items.count == 2 }
        guard case .assistantText(let text) = conv.items[1].kind else {
            return XCTFail("expected assistant text")
        }
        XCTAssertEqual(text, "two")
    }

    @MainActor
    func testRetriesUntilFileExists() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-conv-late-\(UUID().uuidString).jsonl")
        let conv = LiveConversation(url: url)
        defer { conv.stop() }
        XCTAssertFalse(conv.fileFound)
        try "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"late\"}}\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try await Self.eventually(timeout: 3) { conv.fileFound && conv.items.count == 1 }
    }

    @MainActor
    static func eventually(timeout: TimeInterval = 2, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { return XCTFail("condition not met in \(timeout)s") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter LiveConversationTests 2>&1 | tail -5` — Expected: compile failure.

- [ ] **Step 3: Implement**

```swift
import Foundation
import Observation

/// A live view over one Claude session transcript: parses what's
/// already on disk, then tails appends via a vnode watcher. Explicit
/// lifecycle — the owner (ClaudeSessionBinding) calls `stop()` when the
/// binding is replaced or torn down; deinit closes raw descriptors as a
/// backstop. Retries until the file exists: SessionStart can fire
/// before claude's first transcript flush.
@MainActor
@Observable
final class LiveConversation {
    private(set) var items: [TranscriptItem] = []
    private(set) var pendingQuestion: TranscriptAccumulator.PendingQuestion?
    private(set) var fileFound = false

    let url: URL
    @ObservationIgnored private let accumulator = TranscriptAccumulator()
    @ObservationIgnored private var readHandle: FileHandle?
    @ObservationIgnored private nonisolated(unsafe) var watchFD: Int32 = -1
    @ObservationIgnored private nonisolated(unsafe) var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var retryTimer: Timer?

    init(url: URL) {
        self.url = url
        openOrRetry()
    }

    deinit {
        source?.cancel()
        if watchFD >= 0 { close(watchFD) }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        source?.cancel()
        source = nil
        if watchFD >= 0 { close(watchFD) }
        watchFD = -1
        try? readHandle?.close()
        readHandle = nil
    }

    private func openOrRetry() {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.openOrRetry() }
            }
            return
        }
        fileFound = true
        readHandle = handle
        watchFD = open(url.path, O_EVTONLY)
        if watchFD >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: watchFD, eventMask: [.write, .extend], queue: .main)
            src.setEventHandler { [weak self] in self?.drain() }
            src.resume()
            source = src
        }
        drain()
    }

    private func drain() {
        guard let handle = readHandle,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }
        let new = accumulator.feed(data)
        if !new.isEmpty { items.append(contentsOf: new) }
        pendingQuestion = accumulator.pendingQuestion
    }
}
```

(Initial drain runs on main — session transcripts are small at bind time and grow incrementally; the 100MB static-viewer gate doesn't apply to a from-birth tail.)

- [ ] **Step 4: Run tests** — `swift test --filter LiveConversationTests` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/LiveConversation.swift Tests/DreamuxTests/LiveConversationTests.swift
git commit -m "LiveConversation: transcript tailer over TranscriptAccumulator"
```

---

## Group 3 — Binding & input

### Task 6: `ClaudeSessionBinding` + TabSession wiring

**Files:**
- Create: `Sources/Dreamux/Models/ClaudeSessionBinding.swift`
- Modify: `Sources/Dreamux/Models/TabSession.swift`
- Test: `Tests/DreamuxTests/ClaudeSessionBindingTests.swift` (create)

**Interfaces:**
- Consumes: `LiveConversation` (Task 5), `TabSession.init` `onControl` seam (Task 3).
- Produces: `@MainActor @Observable final class ClaudeSessionBinding` — `enum Phase { unbound, working, waitingForUser, idle, ended }`, `phase`, `sessionID: String?`, `claudePID: Int?`, `conversation: LiveConversation?`, `lastNotification: String?`, `hasEverBound: Bool`, `isBound: Bool`, `func handleControl(verb: String, json: Data)`, `func pollRegistryNow()` (test seam), `var registryDirectory: URL` (defaults to `~/.claude/sessions`, overridable via env `DREAMUX_SESSIONS_DIR` for e2e). `TabSession.binding: ClaudeSessionBinding`. Tasks 7–10 consume these names.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Dreamux

@MainActor
final class ClaudeSessionBindingTests: XCTestCase {
    private func control(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    func testBindUnbindLifecycle() {
        let b = ClaudeSessionBinding()
        XCTAssertEqual(b.phase, .unbound)
        XCTAssertFalse(b.hasEverBound)

        b.handleControl(verb: "session-start", json: control([
            "session_id": "s-1", "transcript_path": "/nonexistent/t.jsonl",
            "cwd": "/tmp", "source": "startup", "claude_pid": 4242,
        ]))
        XCTAssertEqual(b.phase, .working)
        XCTAssertEqual(b.sessionID, "s-1")
        XCTAssertEqual(b.claudePID, 4242)
        XCTAssertNotNil(b.conversation)
        XCTAssertTrue(b.isBound && b.hasEverBound)

        b.handleControl(verb: "notify", json: control(["message": "Claude needs your permission"]))
        XCTAssertEqual(b.phase, .waitingForUser)
        XCTAssertEqual(b.lastNotification, "Claude needs your permission")

        b.handleControl(verb: "stop", json: control(["session_id": "s-1"]))
        XCTAssertEqual(b.phase, .idle)
        XCTAssertNil(b.lastNotification, "a finished turn clears the stale banner")

        b.handleControl(verb: "session-end", json: control(["session_id": "s-1"]))
        XCTAssertEqual(b.phase, .ended)
        XCTAssertFalse(b.isBound)
        XCTAssertNotNil(b.conversation, "ended chat stays readable")
    }

    func testRebindReplacesSession() {
        let b = ClaudeSessionBinding()
        b.handleControl(verb: "session-start", json: control(["session_id": "s-1", "transcript_path": "/a.jsonl", "claude_pid": 1]))
        let first = b.conversation
        b.handleControl(verb: "session-start", json: control(["session_id": "s-2", "transcript_path": "/b.jsonl", "claude_pid": 2]))
        XCTAssertEqual(b.sessionID, "s-2")
        XCTAssertFalse(first === b.conversation)
    }

    func testRegistryDrivesPhaseAndDeathDetection() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let b = ClaudeSessionBinding()
        b.registryDirectory = dir
        b.handleControl(verb: "session-start", json: control(["session_id": "s-1", "transcript_path": "/t.jsonl", "claude_pid": 777]))

        try #"{"sessionId":"s-1","status":"waiting","cwd":"/tmp"}"#
            .write(to: dir.appendingPathComponent("777.json"), atomically: true, encoding: .utf8)
        b.pollRegistryNow()
        XCTAssertEqual(b.phase, .waitingForUser)

        try #"{"sessionId":"s-1","status":"busy","cwd":"/tmp"}"#
            .write(to: dir.appendingPathComponent("777.json"), atomically: true, encoding: .utf8)
        b.pollRegistryNow()
        XCTAssertEqual(b.phase, .working)

        // Registry file vanishes while bound → claude died (kill -9).
        try FileManager.default.removeItem(at: dir.appendingPathComponent("777.json"))
        b.pollRegistryNow()
        XCTAssertEqual(b.phase, .ended)
    }

    func testRegistryScanFallbackWhenClaimedPidIsWrong() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let b = ClaudeSessionBinding()
        b.registryDirectory = dir
        // claude_pid 111 is an intermediate shell's pid — no 111.json ever.
        b.handleControl(verb: "session-start", json: control(["session_id": "s-9", "transcript_path": "/t.jsonl", "claude_pid": 111]))

        // Registry not written yet → grace, NOT death.
        b.pollRegistryNow()
        XCTAssertEqual(b.phase, .working)

        // Entry appears under claude's real pid; matched by sessionId.
        try #"{"sessionId":"s-9","status":"waiting"}"#
            .write(to: dir.appendingPathComponent("222.json"), atomically: true, encoding: .utf8)
        b.pollRegistryNow()
        XCTAssertEqual(b.phase, .waitingForUser)

        // A previously-seen entry vanishing IS death.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("222.json"))
        b.pollRegistryNow()
        XCTAssertEqual(b.phase, .ended)
    }

    func testUnknownVerbAndGarbageJsonAreIgnored() {
        let b = ClaudeSessionBinding()
        b.handleControl(verb: "mystery", json: Data("nonsense".utf8))
        b.handleControl(verb: "session-start", json: Data("nonsense".utf8))
        XCTAssertEqual(b.phase, .unbound)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter ClaudeSessionBindingTests 2>&1 | tail -5` — Expected: compile failure.

- [ ] **Step 3: Implement `ClaudeSessionBinding`**

```swift
import Foundation
import Observation

/// Per-tab binding to a live Claude Code session. Consumes the control
/// events dreamux-hook writes into this tab's own PTY (session-start /
/// session-end / notify / stop) and backstops liveness against the
/// session registry file. The chat face renders this object; the write
/// path gates on `phase` — never blind-type.
@MainActor
@Observable
final class ClaudeSessionBinding {
    enum Phase: String, Equatable, Sendable {
        case unbound, working, waitingForUser, idle, ended
    }

    private(set) var phase: Phase = .unbound
    private(set) var sessionID: String?
    private(set) var claudePID: Int?
    private(set) var conversation: LiveConversation?
    /// Latest Notification-hook message (permission request / idle
    /// nudge) — these never appear in the transcript. Cleared when a
    /// turn completes or a new session binds.
    private(set) var lastNotification: String?
    /// Sticky: keeps the face toggle visible after a session ends.
    private(set) var hasEverBound = false

    var isBound: Bool { phase != .unbound && phase != .ended }

    /// `~/.claude/sessions` unless overridden (tests set it directly;
    /// e2e launches the app with DREAMUX_SESSIONS_DIR).
    var registryDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["DREAMUX_SESSIONS_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
    }()

    @ObservationIgnored private var registryTimer: Timer?
    /// True once a registry entry for this session has been read —
    /// gates death-detection so a not-yet-written registry isn't death.
    @ObservationIgnored private var registryEntrySeen = false

    func handleControl(verb: String, json: Data) {
        let payload = ((try? JSONSerialization.jsonObject(with: json)) as? [String: Any]) ?? [:]
        switch verb {
        case "session-start":
            guard let sessionID = payload["session_id"] as? String, !sessionID.isEmpty else { return }
            bind(sessionID: sessionID, payload: payload)
        case "session-end":
            end()
        case "notify":
            guard isBound else { return }
            if let message = payload["message"] as? String, !message.isEmpty {
                lastNotification = message
            }
            phase = .waitingForUser
        case "stop":
            guard isBound else { return }
            phase = .idle
            lastNotification = nil
        default:
            break // forward-compatible: unknown verbs are future protocol
        }
    }

    /// Test seam + timer body: reconcile phase against the registry.
    /// The registry file is named by claude's pid, but the pid the hook
    /// reports (its getppid) can be an intermediate shell's — so fall
    /// back to scanning the directory for our sessionId, and only treat
    /// a MISSING entry as death after we've actually seen one (the
    /// registry may simply not be written yet at bind time).
    func pollRegistryNow() {
        guard isBound else { return }
        guard let entry = registryEntry() else {
            if registryEntrySeen { end() }
            return
        }
        registryEntrySeen = true
        switch entry["status"] as? String {
        case "busy": phase = .working
        case "waiting": phase = .waitingForUser
        case "idle": phase = .idle
        default: break
        }
    }

    /// The registry dict for OUR session: the claimed-pid file if it
    /// matches our sessionId, else the first directory entry that does.
    private func registryEntry() -> [String: Any]? {
        func load(_ url: URL) -> [String: Any]? {
            guard let data = try? Data(contentsOf: url),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return nil }
            if let registrySession = dict["sessionId"] as? String,
               let bound = sessionID, registrySession != bound {
                return nil // different/stale session — not ours
            }
            return dict
        }
        if let pid = claudePID,
           let dict = load(registryDirectory.appendingPathComponent("\(pid).json")) {
            return dict
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: registryDirectory, includingPropertiesForKeys: nil) else { return nil }
        for file in files where file.pathExtension == "json" {
            if let dict = load(file) { return dict }
        }
        return nil
    }

    private func bind(sessionID: String, payload: [String: Any]) {
        conversation?.stop()
        self.sessionID = sessionID
        claudePID = payload["claude_pid"] as? Int
        lastNotification = nil
        registryEntrySeen = false
        hasEverBound = true
        if let path = payload["transcript_path"] as? String, !path.isEmpty {
            conversation = LiveConversation(url: URL(fileURLWithPath: path))
        } else {
            conversation = nil
        }
        phase = .working
        registryTimer?.invalidate()
        registryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollRegistryNow() }
        }
    }

    private func end() {
        guard phase != .ended else { return }
        phase = .ended
        registryTimer?.invalidate()
        registryTimer = nil
        conversation?.stop() // stop tailing; items stay readable
    }
}
```

- [ ] **Step 4: Wire into `TabSession`**

In `TabSession`: add `let binding = ClaudeSessionBinding()` above the `init`, and change the shell construction (`init` currently `self.shell = PTYShellSession(cwd: cwd, onActivity: onActivity)`) to:

```swift
        let binding = self.binding
        self.shell = PTYShellSession(
            cwd: cwd,
            onActivity: onActivity,
            onControl: { verb, json in
                Task { @MainActor in binding.handleControl(verb: verb, json: json) }
            }
        )
```

(Property initializers run before `init` bodies, so `self.binding` is available; capture it in a local to avoid touching `self` inside the `@Sendable` closure.) If the compiler rejects the early `self.binding` read, initialize `binding` as a local `let binding = ClaudeSessionBinding()` first and assign both.

- [ ] **Step 5: Run tests** — `swift test --filter ClaudeSessionBindingTests && swift build` — Expected: PASS, clean build.

- [ ] **Step 6: Commit**

```bash
git add Sources/Dreamux/Models/ClaudeSessionBinding.swift Sources/Dreamux/Models/TabSession.swift Tests/DreamuxTests/ClaudeSessionBindingTests.swift
git commit -m "ClaudeSessionBinding: per-tab session state machine wired to control OSCs"
```

### Task 7: `PromptKeystrokeRecipes` + gated input API

**Files:**
- Create: `Sources/Dreamux/Shell/PromptKeystrokeRecipes.swift`
- Modify: `Sources/Dreamux/Models/TabSession.swift`
- Test: `Tests/DreamuxTests/PromptKeystrokeRecipesTests.swift` (create)

**Interfaces:**
- Consumes: `TabSession.send`, `binding.phase`, `conversation.pendingQuestion`.
- Produces: `enum PromptKeystrokeRecipes` — `static func promptSend(_ text: String) -> String`, `static func selectOption(at index: Int) -> String`, `static func selectOptions(at indices: [Int]) -> String`, `static func selectOtherAndType(optionCount: Int, text: String) -> String`, `static let interrupt: String`, `static func permissionRecipe(forNotification message: String) -> String?` (**ships returning nil for everything** — the quarantined, deliberately-empty table). `TabSession`: `func sendChatPrompt(_ text: String) -> Bool`, `func answerQuestion(selecting indices: [Int]) -> Bool`, `func answerQuestionOther(text: String) -> Bool`, `func interruptClaude()`. Task 8 consumes these exactly.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import Dreamux

final class PromptKeystrokeRecipesTests: XCTestCase {
    func testPromptSendWrapsInBracketedPaste() {
        XCTAssertEqual(
            PromptKeystrokeRecipes.promptSend("hi\nthere"),
            "\u{1B}[200~hi\nthere\u{1B}[201~\r")
    }

    func testSingleSelect() {
        XCTAssertEqual(PromptKeystrokeRecipes.selectOption(at: 0), "\r")
        XCTAssertEqual(PromptKeystrokeRecipes.selectOption(at: 2), "\u{1B}[B\u{1B}[B\r")
    }

    func testMultiSelectWalksDownwardOnce() {
        // Toggle options 0 and 2 (cursor starts at 0): space, down×2, space, enter.
        XCTAssertEqual(
            PromptKeystrokeRecipes.selectOptions(at: [2, 0]),
            " \u{1B}[B\u{1B}[B \r")
    }

    func testOtherIsOnePastTheLastOption() {
        // 2 options → Other at index 2: down×2, enter, text, enter.
        XCTAssertEqual(
            PromptKeystrokeRecipes.selectOtherAndType(optionCount: 2, text: "custom"),
            "\u{1B}[B\u{1B}[B\rcustom\r")
    }

    func testPermissionTableShipsEmpty() {
        XCTAssertNil(PromptKeystrokeRecipes.permissionRecipe(
            forNotification: "Claude needs your permission to use Bash"))
    }

    func testInterrupt() {
        XCTAssertEqual(PromptKeystrokeRecipes.interrupt, "\u{1B}")
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter PromptKeystrokeRecipesTests 2>&1 | tail -5` — Expected: compile failure.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Keystroke recipes for Claude Code's interactive TUI. THE deliberately
/// version-fragile file: everything that assumes how claude's dialogs
/// respond to keys lives here, unit tested, and gets re-verified against
/// each Claude Code upgrade (docs/claude-chat-face-smoke.md). Senders
/// must gate on ClaudeSessionBinding state — never blind-type.
enum PromptKeystrokeRecipes {
    private static let esc = "\u{1B}"
    private static let down = "\u{1B}[B"
    private static let enter = "\r"

    /// Main composer: bracketed paste keeps multi-line prompts one
    /// input event, then Enter submits.
    static func promptSend(_ text: String) -> String {
        esc + "[200~" + text + esc + "[201~" + enter
    }

    /// Single-select question; cursor starts on option 0.
    static func selectOption(at index: Int) -> String {
        String(repeating: down, count: max(0, index)) + enter
    }

    /// Multi-select question: walk downward toggling with Space, then
    /// submit. Indices beyond the cursor only — one pass, no wrapping.
    static func selectOptions(at indices: [Int]) -> String {
        var out = ""
        var cursor = 0
        for index in Set(indices).sorted() {
            out += String(repeating: down, count: index - cursor) + " "
            cursor = index
        }
        return out + enter
    }

    /// "Other" sits one past the last listed option; selecting it opens
    /// a free-text field.
    static func selectOtherAndType(optionCount: Int, text: String) -> String {
        String(repeating: down, count: optionCount) + enter + text + enter
    }

    /// Permission dialogs: recipes keyed on recognized Notification
    /// messages. Ships EMPTY on purpose — every permission request
    /// degrades to the "Respond in terminal" banner until a pattern has
    /// been verified against real payloads. Add entries here only with
    /// a matching smoke-checklist run.
    static func permissionRecipe(forNotification message: String) -> String? {
        nil
    }

    static let interrupt = esc
}
```

- [ ] **Step 4: Add gated conveniences to `TabSession`** (below `send(_:)`):

```swift
    // MARK: - Chat-face input (gated — never blind-type)

    /// Send a composer prompt into the bound claude TUI. Returns false
    /// (and sends nothing) unless the session is at its input prompt.
    @discardableResult
    func sendChatPrompt(_ text: String) -> Bool {
        guard binding.phase == .idle || binding.phase == .waitingForUser,
              binding.conversation?.pendingQuestion == nil,
              !text.isEmpty else { return false }
        shell.send(PromptKeystrokeRecipes.promptSend(text))
        return true
    }

    /// Answer the pending AskUserQuestion by option indices (single- or
    /// multi-select decided by the question itself).
    @discardableResult
    func answerQuestion(selecting indices: [Int]) -> Bool {
        guard binding.phase == .waitingForUser,
              let question = binding.conversation?.pendingQuestion?.questions.first,
              let first = indices.first, indices.allSatisfy({ (0..<question.options.count).contains($0) })
        else { return false }
        shell.send(question.multiSelect
            ? PromptKeystrokeRecipes.selectOptions(at: indices)
            : PromptKeystrokeRecipes.selectOption(at: first))
        return true
    }

    /// Answer the pending question with free text via its Other row.
    @discardableResult
    func answerQuestionOther(text: String) -> Bool {
        guard binding.phase == .waitingForUser,
              let question = binding.conversation?.pendingQuestion?.questions.first,
              !text.isEmpty else { return false }
        shell.send(PromptKeystrokeRecipes.selectOtherAndType(
            optionCount: question.options.count, text: text))
        return true
    }

    /// ESC — stop the current turn.
    func interruptClaude() {
        guard binding.isBound else { return }
        shell.send(PromptKeystrokeRecipes.interrupt)
    }
```

(v1 answers the FIRST question of a multi-question AskUserQuestion; multi-question dialogs advance to the next question after each answer, and the pendingQuestion updates only when the whole tool_result lands — acceptable: the buttons re-render from the same first question, and repeated answering walks through. If that proves confusing in smoke testing, the banner falls back to "Respond in terminal" when `questions.count > 1` — one-line change in Task 8's banner.)

- [ ] **Step 5: Run tests** — `swift test --filter PromptKeystrokeRecipesTests && swift build` — Expected: PASS, clean build.

- [ ] **Step 6: Commit**

```bash
git add Sources/Dreamux/Shell/PromptKeystrokeRecipes.swift Sources/Dreamux/Models/TabSession.swift Tests/DreamuxTests/PromptKeystrokeRecipesTests.swift
git commit -m "Chat input: keystroke recipes + gated TabSession send APIs"
```

---

## Group 4 — UI & end-to-end

### Task 8: Shared rows + `ChatFaceView`

**Files:**
- Create: `Sources/Dreamux/Views/Viewers/TranscriptRows.swift` (moved rows)
- Create: `Sources/Dreamux/Views/ChatFaceView.swift`
- Create: `Sources/Dreamux/Models/SubagentTranscriptLocator.swift`
- Modify: `Sources/Dreamux/Views/Viewers/TranscriptView.swift` (delete moved rows)
- Test: `Tests/DreamuxTests/SubagentTranscriptLocatorTests.swift` (create)

**Interfaces:**
- Consumes: `TranscriptRow` (moved), `TabSession.binding` + input APIs (Tasks 6–7), `SoftButtonStyle`, `TranscriptItem.Kind.toolUse` id (Task 4).
- Produces: `struct ChatFaceView: View { let tab: TabSession; let onFlipToTerminal: () -> Void; let onOpenTranscript: (URL) -> Void }`; `SubagentTranscriptLocator.transcript(forToolUseID:parentTranscript:) -> URL?`. Task 9 mounts/wires both.

View task — anchored sketch, build-gated; e2e verifies in Task 10. No unit tests for the view (house style); the locator is a pure helper and IS unit tested.

- [ ] **Step 1: Move rows.** Cut `TranscriptRow`, `MessageBlock`, `CollapsibleBlock` from `TranscriptView.swift:199-307` into `Views/Viewers/TranscriptRows.swift` unchanged except: drop `private` from all three (module-internal), keep `MessageBlock`'s cleared-background MarkdownUI theme exactly as is. `swift build` — clean.

- [ ] **Step 2: `SubagentTranscriptLocator` (TDD).** Test first — temp dir shaped like a real session (`<dir>/<uuid>.jsonl` + `<dir>/<uuid>/subagents/agent-1.meta.json` containing `{"toolUseId":"tu-1","spawnDepth":1}` + `agent-1.jsonl`): `transcript(forToolUseID: "tu-1", parentTranscript: <url>)` returns the `agent-1.jsonl` URL; `"tu-other"` returns nil; missing `subagents/` dir returns nil. Then:

```swift
import Foundation

/// Finds a subagent's transcript beside its parent session transcript
/// (projects/<slug>/<session-uuid>/subagents/agent-<n>.jsonl), joined
/// via the sidecar meta.json whose `toolUseId` matches the parent
/// transcript's Agent tool_use id.
enum SubagentTranscriptLocator {
    static func transcript(forToolUseID toolUseID: String, parentTranscript: URL) -> URL? {
        let subagents = parentTranscript.deletingPathExtension()
            .appendingPathComponent("subagents")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: subagents, includingPropertiesForKeys: nil) else { return nil }
        for meta in entries where meta.lastPathComponent.hasSuffix(".meta.json") {
            guard let data = try? Data(contentsOf: meta),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  dict["toolUseId"] as? String == toolUseID else { continue }
            let jsonl = meta.deletingLastPathComponent().appendingPathComponent(
                meta.lastPathComponent.replacingOccurrences(of: ".meta.json", with: ".jsonl"))
            return FileManager.default.fileExists(atPath: jsonl.path) ? jsonl : nil
        }
        return nil
    }
}
```

Run: `swift test --filter SubagentTranscriptLocatorTests` — Expected: PASS.

- [ ] **Step 3: Build `ChatFaceView`.** Structure (follow CLAUDE.md scale everywhere):

```swift
import SwiftUI

/// The Chat face of a terminal tab bound to a live Claude Code session:
/// live conversation from the transcript tailer, honest status chip,
/// question/permission banners, and a composer that types into the PTY.
/// The Terminal face is always one flip away — and is the mandatory
/// fallback for anything this face doesn't positively recognize.
struct ChatFaceView: View {
    let tab: TabSession
    let onFlipToTerminal: () -> Void
    let onOpenTranscript: (URL) -> Void

    @State private var draft = ""
    @State private var otherText = ""
    @State private var multiSelection: Set<Int> = []
    /// Set when a question answer is injected; if the pendingQuestion
    /// hasn't cleared ~3s later, the banner adds a "that didn't seem to
    /// land — respond in terminal" note (spec: watch for the expected
    /// state advance after every injection).
    @State private var answerInjectedAt: Date?

    private var binding: ClaudeSessionBinding { tab.binding }

    var body: some View {
        VStack(spacing: 0) {
            header
            conversation
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    // …
}
```

- **header**: HStack — status chip (`Circle().frame(width: 8)` tinted per phase: working `.orange`, waitingForUser `.blue`, idle `.green`, ended `.secondary`; label 13pt medium `.secondary`: "Working…" / "Waiting for you" / "Idle" / "Session ended") + Spacer. Padding 12/16. No divider under it — spacing only.
- **conversation**: `ScrollViewReader` + `ScrollView { LazyVStack(alignment: .leading, spacing: 22) { ForEach(items) { row(for: $0) }; Color.clear.frame(height: 1).id("bottom") } .padding(.horizontal, 28).padding(.vertical, 22).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity) }` — same geometry as `TranscriptView`. `.onChange(of: items.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }`. `items` = `binding.conversation?.items ?? []`. Empty + `fileFound == false` → centered "Waiting for the session transcript…" 13pt `.secondary`. `row(for:)` renders `TranscriptRow(item:)` for everything except subagent calls: `if case .toolUse(let id?, let name, _) = item.kind, name == "Agent" || name == "Task"`, append under the card a borderless 13pt `.secondary` link row ("Open subagent transcript", `arrow.up.right` glyph, hover-only wash) that on click resolves `SubagentTranscriptLocator.transcript(forToolUseID: id, parentTranscript: binding.conversation!.url)` and calls `onOpenTranscript(url)` when found (silent no-op when not — the subagent may not have written yet).
- **footer** (VStack, spacing 10, padding 16, top spacing generous):
  - If `binding.conversation?.pendingQuestion` is non-nil and `binding.phase == .waitingForUser`: **question banner** — question text 15pt medium; then per option a full-width button (`SoftButtonStyle`): label 14pt primary + description 12pt `.secondary`, leading-aligned. Single-select: tap → `tab.answerQuestion(selecting: [index])`. Multi-select: taps toggle `multiSelection` (checkmark leading glyph), plus a "Submit" soft button → `tab.answerQuestion(selecting: Array(multiSelection))`, then `multiSelection = []`. Below options: an "Other…" `TextField` (14pt) + Send soft button → `tab.answerQuestionOther(text: otherText)`. Every successful injection sets `answerInjectedAt = Date()`; a 1s `TimelineView`/timer check shows "That didn't seem to land — respond in terminal" (13pt `.orange`) when `answerInjectedAt` is >3s old and the same `pendingQuestion.toolUseID` is still pending; cleared whenever `pendingQuestion` changes. Foot row: borderless "Respond in terminal" (plain `terminal` glyph, 13pt, `.secondary`, hover-only wash) → `onFlipToTerminal()`. If `pendingQuestion.questions.count > 1`, replace options with a note "Multiple questions — respond in terminal" + the flip row (see Task 7 note).
  - Else if `binding.lastNotification != nil` and `binding.phase == .waitingForUser`: **notification banner** — `exclamationmark.bubble` glyph + message 14pt; if `PromptKeystrokeRecipes.permissionRecipe(forNotification:)` returns a recipe show Allow via `tab.send(recipe)` (won't in v1 — table is empty), always show "Respond in terminal" flip row.
  - Else if `binding.phase == .ended`: dimmed "Session ended — start `claude` in the terminal to begin a new one." + flip row.
  - **Composer** (hidden when `.ended`): `TextField("Message Claude…", text: $draft, axis: .vertical)` 15pt, `.lineLimit(1...6)`, `.textFieldStyle(.plain)`, padding 10, on `RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.3))`; trailing send soft button (`arrow.up.circle.fill`, disabled unless `sendChatPrompt` would fire — mirror its gate) → `if tab.sendChatPrompt(draft) { draft = "" }`; `.onSubmit` same; while `binding.phase == .working` swap send for an interrupt soft button (`stop.circle`) → `tab.interruptClaude()`.

- [ ] **Step 4: Build gate** — `swift build && swift test` — Expected: clean, all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Views/Viewers/TranscriptRows.swift Sources/Dreamux/Views/ChatFaceView.swift Sources/Dreamux/Models/SubagentTranscriptLocator.swift Tests/DreamuxTests/SubagentTranscriptLocatorTests.swift Sources/Dreamux/Views/Viewers/TranscriptView.swift
git commit -m "ChatFaceView: live conversation, banners, gated composer, subagent links"
```

### Task 9: Face toggle in the tab

**Files:**
- Modify: `Sources/Dreamux/Models/TabSession.swift`
- Modify: `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift`

**Interfaces:**
- Consumes: `ChatFaceView` (Task 8), `TabSession.binding`.
- Produces: `TabSession.face: TabFace` (`enum TabFace { case chat, terminal }`), `func autoFlipToChatOnce()`.

View task — anchored sketch, build-gated; e2e verifies in Task 10.

- [ ] **Step 1: Face state on `TabSession`**

```swift
    enum TabFace: Equatable { case chat, terminal }
    /// Which face this tab shows. Terminal until a session first binds,
    /// then auto-flips to chat ONCE; after that the user's choice sticks
    /// (in-memory — tabs don't persist across launches).
    var face: TabFace = .terminal
    @ObservationIgnored private var didAutoFlip = false

    func autoFlipToChatOnce() {
        guard !didAutoFlip else { return }
        didAutoFlip = true
        face = .chat
    }
```

- [ ] **Step 2: Mount in `TabContentView`.** Replace the terminal branch (`WorkspaceTerminalContainer.swift:107-118`) with:

```swift
        } else if let tabSession = session.tabSession(for: tabId) {
            let isSelectedTab = session.controller.isTabSelected(tabId)
            ZStack(alignment: .topTrailing) {
                if tabSession.face == .chat, tabSession.binding.hasEverBound {
                    ChatFaceView(
                        tab: tabSession,
                        onFlipToTerminal: { tabSession.face = .terminal },
                        onOpenTranscript: { session.openFileTab(at: $0) }
                    )
                } else {
                    HostedTerminalView(session: tabSession, dropTargetEnabled: isSelectedTab)
                        .onAppear { tabSession.startIfNeeded() }
                }
                if tabSession.binding.hasEverBound {
                    FaceTogglePill(tab: tabSession)
                        .padding(.top, 8)
                        .padding(.trailing, 12)
                }
            }
            .onChange(of: tabSession.binding.hasEverBound) { _, bound in
                if bound { tabSession.autoFlipToChatOnce() }
            }
```

(The terminal NSView is session-owned and survives unmounting — documented on `TabSession.terminalView` — and `face` starts `.terminal`, so `startIfNeeded()` always runs before any flip.)

- [ ] **Step 3: `FaceTogglePill`** (private, same file): the house outlined pill — `HStack(spacing: 0)` of two segments ("Chat", "Terminal", 13pt medium; active segment `.primary` on `Color.primary.opacity(0.08)`, inactive `.secondary`, hover wash `0.04`), 1pt hairline divider between, on `RoundedRectangle(cornerRadius: 8)` with `strokeBorder(.secondary.opacity(0.3))` + `.primary.opacity(0.04)` fill, background `.ultraThinMaterial` so it reads over terminal content. Click sets `tab.face`.

- [ ] **Step 4: Build gate** — `swift build && swift test` — Expected: clean, all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/TabSession.swift Sources/Dreamux/Views/WorkspaceTerminalContainer.swift
git commit -m "Tabs: Chat|Terminal face toggle with one-time auto-flip on bind"
```

### Task 10: fake-claude e2e + smoke checklist

**Files:**
- Create: `Scripts/e2e/fake-claude`
- Create: `docs/claude-chat-face-smoke.md`
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift` (one query command)
- Modify: `Scripts/e2e/PROTOCOL.md` (document it)

**Interfaces:**
- Consumes: control-OSC protocol (Task 1), binding (Task 6), faces (Task 9).
- Produces: `fake-claude [--transcript-fixture <path>]` — deterministic session simulator; e2e command `chatFaceState` → `{"phase": "...", "items": N, "face": "chat|terminal", "pendingQuestion": bool}` for the active tab.

- [ ] **Step 1: Write `Scripts/e2e/fake-claude`** (python3, executable). Behavior: create a temp transcript; emit `session-start` control OSC to stdout (stdout IS the tab's tty when run in a tab) with `{session_id, transcript_path, cwd, source:"startup", claude_pid: os.getpid()}`; write its own registry file `$DREAMUX_SESSIONS_DIR/<pid>.json` (`status":"busy"`) when that env var is set (never touches the real `~/.claude`); then replay a built-in timeline (user line → 0.3s → assistant thinking+text → 0.3s → AskUserQuestion tool_use, registry flips to `waiting`) and **wait for a line on stdin**; on receiving anything, append the matching `tool_result` + a closing assistant text, emit `stop` control OSC, flip registry to `idle`; on EOF/second input emit `session-end` and exit, removing its registry file. Reuse Task 1's `control_emit` encoding inline (same 8 lines — the script must be standalone).

- [ ] **Step 2: Verify standalone**

```bash
printf '\n' | Scripts/e2e/fake-claude | python3 -c '
import sys, re
out = sys.stdin.buffer.read().decode()
for verb in ("session-start", "stop", "session-end"):
    assert re.search(r"\x1b\]777;dreamux;%s;" % verb, out), verb
print("fake-claude OK")'
```

Expected: `fake-claude OK`.

- [ ] **Step 3: Add `chatFaceState` to `E2ECommands.swift`** (dispatch at :52-120, follow an existing query case): resolve active workspace's selected tab's `TabSession`, reply with the JSON above (phase `rawValue`, `binding.conversation?.items.count ?? 0`, face, `pendingQuestion != nil`). Document in `Scripts/e2e/PROTOCOL.md`.

- [ ] **Step 4: End-to-end run** (manual driver invocation, screenshots to scratchpad): launch the app e2e build with `DREAMUX_SESSIONS_DIR` pointing at a temp dir, open a workspace tab, type `Scripts/e2e/fake-claude` + Enter into the terminal, poll `chatFaceState` until `phase == "waitingForUser" && pendingQuestion == true && face == "chat"` (auto-flip happened), screenshot (chat face with question banner), click the first option via the question banner (or drive `answerQuestion` through an existing e2e input path), poll until `phase == "idle"` and `items` grew, screenshot again. Assert both screenshots exist and `chatFaceState` outputs matched. Remember: manual sandbox launches need `-ApplePersistenceIgnoreState YES`; capture is contentView-only.

- [ ] **Step 5: Write `docs/claude-chat-face-smoke.md`** — the per-Claude-Code-upgrade manual checklist: (1) run real `claude` in a tab → chat face auto-flips, status chip tracks busy/waiting; (2) send a composer prompt → lands verbatim in the TUI (flip to Terminal to confirm), response streams into chat; (3) trigger an AskUserQuestion → options render, clicking selects the right one; (4) multiSelect question → toggles + submit select correctly; (5) Other → free text lands; (6) trigger a permission prompt → banner appears, "Respond in terminal" flips; (7) Ctrl-flip interrupt button stops a turn; (8) `/clear`, `--resume`, quit-and-rerun → rebind each time; (9) `kill -9` the claude process → face shows Session ended within ~2s. Note at top: **re-run whenever the pinned Claude Code version changes; `PromptKeystrokeRecipes` is the file under test.**

- [ ] **Step 6: Full suite + commit**

```bash
swift build && swift test
git add Scripts/e2e/fake-claude docs/claude-chat-face-smoke.md Sources/Dreamux/E2E/E2ECommands.swift Scripts/e2e/PROTOCOL.md
git commit -m "e2e: fake-claude session simulator + chatFaceState + smoke checklist"
```
