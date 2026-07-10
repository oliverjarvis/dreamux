# Claude chat face for terminal tabs — design

A second, native face on any terminal tab running interactive Claude Code:
the live conversation rendered as chat — messages, thinking, tool activity,
questions — with the ability to respond from it. The raw terminal stays one
flip away and remains the escape hatch for anything the chat face can't do.

## Problem

All interfacing with Claude Code happens through the raw CLI. The terminal
is fine for typing but poor at *reading* a session: markdown renders as
plain text, AskUserQuestion dialogs are cramped TUI widgets, tool activity
is a spinner line, and past turns scroll away. We want a view that reflects
the *actual running interactive session* — not a `-p`/SDK re-host (a
different session entirely) and not ANSI screen-scraping (strictly worse
than the structured data Claude Code already writes).

The established ecosystem pattern (opcode, sniffly, cmux) is to treat the
session's on-disk surfaces as the API: transcripts for content, hooks and
the session registry for state. Dreamux is unusually well positioned — it
owns the PTY, so it also has a *write* path no external observer has.

## Concepts

- **Face** — a terminal tab has two faces, **Chat** and **Terminal**,
  switched by a segmented control in the tab header. One tab, one PTY, one
  session; the face is only which lens you're looking through. The PTY and
  its terminal view keep running regardless of the visible face.
- **Binding** — the association between a tab and a live Claude session
  (session id + transcript path + claude pid). Established by a
  `SessionStart` hook event that travels *through the tab's own PTY* as an
  escape sequence, so it arrives pre-correlated — no registry scanning, no
  env matching. A tab with no binding is a pure terminal.
- **Three channels**, each doing the one thing it's good at:
  - *Content (read)*: tail the session transcript JSONL — the only
    complete record of message text.
  - *State (read)*: hook events (permission requests, turn boundaries,
    session lifecycle) plus the `~/.claude/sessions/<pid>.json` registry
    as a liveness backstop.
  - *Input (write)*: the PTY. Typed prompts, question answers, and
    permission responses are injected as the keystrokes the user would
    have typed — always visible on the terminal face.
- **Never blind-type** — the write path only fires when hook + registry
  state agree the CLI is at the exact prompt being answered. Anything
  unrecognized degrades to a "Respond in terminal" banner with a one-click
  flip.

## Binding lifecycle

The `Tools/claude` shim gains a `SessionStart` entry in its injected
`--settings` hooks (async, empty matcher — fires on startup, `--resume`,
`--continue`, `/clear`, and compaction alike). A new `dreamux-hook
session-start` subcommand reads the hook stdin JSON (`session_id`,
`transcript_path`, `cwd`, `source`), adds the claude pid (`os.getppid()` —
the hook runs as claude's child), and emits the payload as a **control
OSC** on `/dev/tty`: an `OSC 777 ; dreamux ; session-start ; <base64url
JSON> BEL` sequence. Base64url keeps the payload free of semicolons and
terminators so `splitSemicolons` can't clip it.

`PTYShellSession.extractActivitySignals` currently returns `[String?]`
(notification bodies). It becomes a typed enum:

```
enum ActivitySignal {
    case ping                     // bare BEL
    case notification(String)     // OSC 9 / OSC 777;notify — existing path
    case control(verb: String, payload: Data)  // OSC 777;dreamux;<verb>;<b64>
}
```

Control signals route to the tab's `TabSession` instead of the
notification pipeline. On `session-start` the tab **binds**: it records
session id, transcript path, and claude pid, starts the transcript tailer
and registry watcher, and the chat face becomes available.

A matching `session-end` control OSC **unbinds** — emitted by `dreamux-hook
flow`'s existing `SessionEnd` handling, which dual-emits the control OSC
alongside its signal-socket relay (no new shim entry needed). The
conversation stays rendered but dimmed, header shows "Session ended",
composer disabled. A new
`session-start` on the same tab (quit and relaunch, resume, clear)
replaces the binding and resets the conversation model. If claude dies
without `SessionEnd` (kill -9), the registry watcher notices the
`sessions/<pid>.json` file vanish and marks the binding ended.

Unshimmmed claude (`DREAMUX_CLAUDE_INTEGRATION=0`, or a direct path to the
real binary) never binds; the tab stays a pure terminal with no chat-face
UI at all.

## Read path — content

`TranscriptParser` (already a standalone enum inside `TranscriptView.swift`)
moves to `Models/TranscriptParser.swift` and gains an incremental API: feed
it appended bytes, it maintains a partial-trailing-line buffer and returns
item changes. Assistant turns arrive one JSONL line per content block —
items are grouped by `message.id`, so a later line with the same id
*updates* an existing turn rather than appending a new one.

`TranscriptTailer` owns the file: on bind it parses the whole existing file
(covers opening the chat face mid-session), then watches for appends with a
`DispatchSource` file-system object source, feeding new bytes to the parser
by byte offset. The transcript is append-only for a session's lifetime;
path changes only via rebinding (resume writes a new session file), which
supplies a fresh tailer.

Both feed a per-binding `@Observable` conversation model rendering:

- **User messages** and **assistant markdown** (MarkdownUI, library page
  backgrounds cleared per house style).
- **Thinking** behind a collapsed disclosure.
- **Tool calls** as collapsed cards — icon, tool name, one-line summary —
  expanding to input/result detail. `tool_use`/`tool_result` pairs join by
  tool-use id. Oversized results spill to `tool-results/*.txt`; v1 renders
  whatever stub the transcript line carries (lazy spill-file loading is
  deferred — see Deferred).
- **Agent (subagent) calls** as cards summarizing the task, with a link
  that opens the subagent's transcript
  (`projects/<slug>/<session>/subagents/agent-<id>.jsonl`) in the existing
  static `TranscriptView` tab (`FileTabKind.transcript`). No inline
  subagent rendering in v1.

## Read path — state

Per-binding state machine: `bound(busy)` → `bound(waitingPrompt)` /
`bound(waitingDialog(kind))` → `ended`. Sources, in trust order:

1. **`Notification` hook** — the only source for permission requests and
   idle-waiting nudges (these never appear in the transcript).
   `dreamux-hook notify` keeps emitting its human-readable OSC 9 for the
   notification pipeline and *additionally* emits a structured control OSC
   with the full stdin payload for the binding's state machine.
2. **`Stop` hook** — assistant turn complete (fires every turn; it is NOT
   session-terminal — `SessionEnd` is).
3. **Transcript shape** — a trailing `AskUserQuestion` `tool_use` with no
   `tool_result` while the session is waiting ⇒ a question dialog is up,
   and its JSON supplies the question text and options to render.
4. **Registry backstop** — watch `~/.claude/sessions/<pid>.json` (pid from
   the binding) for `idle|busy|waiting` and liveness; reconciles missed
   hooks.

The chat face header shows an honest status chip: *Working…*, *Waiting for
you*, *Idle*, *Session ended*.

## Write path

All input goes through `PTYShellSession.send(_:)` and is therefore visible
on the terminal face — flipping over shows exactly what the chat face
"typed". One injection in flight at a time; after each, the binding watches
for the expected state advance (transcript append or hook event) and
reverts to a "Respond in terminal" banner if it doesn't come.

- **Composer** (pinned at the bottom): sends the prompt wrapped in
  bracketed paste (`ESC[200~ … ESC[201~`) followed by CR — claude's TUI
  input handles multi-line pastes natively. Long sends are chunked;
  `ClaudePromptDriver`'s echo-verification wisdom applies (silence after a
  send means the bytes were flushed, not delivered). Enabled only in
  `waitingPrompt`/idle states with no dialog up.
- **Question dialogs**: options render as real buttons (question text,
  option labels + descriptions, from the `tool_use` JSON). A click
  translates to keystrokes via `PromptKeystrokeRecipes` — single-select:
  Down×n + Enter from the known initial cursor position; multi-select:
  arrow/Space toggles per selected option, then Enter; "Other": select it,
  then type the free text + Enter.
- **Permission requests**: the `Notification` payload carries message text,
  not dialog structure, so recipes are keyed on recognized message
  patterns. Recognized ⇒ Allow / Deny buttons; unrecognized ⇒ banner +
  flip button only. Deliberately conservative in v1.
- **Interrupt**: a stop button sends ESC.

`PromptKeystrokeRecipes` is one small table — the deliberately
version-fragile part of the system, quarantined in a single file, unit
tested, and reviewed against each Claude Code upgrade. Every recipe is
gated on positive dialog recognition; the default for anything unknown is
the flip banner, never a guess.

## UI

### Face toggle

Segmented **Chat | Terminal** control in the tab header using the house
outlined-pill shape (cornerRadius 8, `strokeBorder` `.secondary.opacity(0.3)`,
hairline segment divider). It appears once the tab first binds — never on
pure shell tabs. On first bind the tab auto-flips to Chat; afterwards the
user's last-chosen face is remembered per tab.

### Chat face

Header: status chip + session metadata (model, cwd) when known. Body: the
conversation, generous per house style — 14–15pt message text, roomy
vertical rhythm, one hover wash for interactive rows, content sitting
directly on the app surface (no floating card). Footer: pending-dialog
banner area (question buttons / permission banner / "Respond in terminal")
above the composer with its send and interrupt controls.

### Terminal face

Unchanged. The PTY renders continuously on both faces' behalf; flipping is
instant and lossless in both directions.

## Error handling

- **No shim / opt-out** → tab never binds; zero chat-face chrome.
- **Transcript missing or unreadable at bind** → chat face shows a banner
  and keeps retrying via the watcher; terminal unaffected.
- **Malformed JSONL lines** → lenient parser skips them (existing
  behavior); partial trailing lines buffer until complete.
- **Missed hook events** → registry watcher reconciles state; worst case
  the status chip lags, never lies.
- **Claude killed hard** → registry file vanishes → binding marked ended.
- **Injection uncertainty** (state sources disagree, unknown dialog,
  no post-injection advance) → controls disable, flip banner appears.
- **Secrets**: nothing under `~/.claude` is written, and
  `ide/<pid>.lock` / `daemon/control.key` are never read.

## Testing

- **Parser**: extend `TranscriptParserTests` — incremental appends,
  partial-line buffering, `message.id` turn-grouping, tool pair joining,
  real transcript fixtures.
- **Tailer**: temp-file tests — append while watching, open-mid-file,
  replacement on rebind.
- **Control OSC**: unit tests on the typed `extractActivitySignals` —
  round-trip `session-start`/`session-end`/structured-notify payloads,
  interleaved with ordinary output and legacy OSC 9 notifications.
- **Recipes**: unit tests mapping dialog descriptions → keystroke strings.
- **End-to-end**: a `fake-claude` script that replays a recorded transcript
  (writing JSONL lines on a timeline) and emits the same control OSCs,
  making the whole read path deterministic; drive it in a tab and
  screenshot the chat face on the existing e2e harness.
- **Real CLI**: a short manual smoke checklist (bind, ask a question,
  answer from chat, permission banner, interrupt, session end) run against
  each Claude Code upgrade, since the write path is coupled to its TUI.

## Deferred (designed-for, not built)

- **Inline subagent conversations** — v1 links out to the static viewer.
- **Full permission parity** — v1 handles recognized patterns only (and
  the recognized-pattern table ships empty until verified against real
  payloads: every permission request degrades to banner + flip).
- **Lazy loading of oversized spilled tool results** — the on-disk stub
  format inside the transcript line is unverified; v1 renders the stub
  text as-is rather than guessing a join.
- **Multi-question AskUserQuestion dialogs** — v1 answers single-question
  dialogs from the chat face; multi-question ones degrade to the
  "Respond in terminal" banner (never blind-type through a dialog whose
  cursor state we can't model).
- **Slash-command affordances** (model picker, /compact button) from the
  chat face.
- **Multiple concurrent claude processes in one tab** (tmux panes) — v1
  binds the most recent `session-start`.
- **Other agents** (codex rollout JSONLs, opencode's SSE server) — the
  face/binding split is agent-agnostic by design; only the channels are
  Claude-specific.

## Key integration seams (from codebase exploration)

- `Sources/Dreamux/Views/Viewers/TranscriptView.swift:106` —
  `TranscriptParser` already a standalone enum; move to Models and extend
  incrementally. `TranscriptItem` (line 87) is the shared item model.
- `Sources/Dreamux/Shell/PTYShellSession.swift:333` —
  `extractActivitySignals` is the OSC seam; `send(_:)` (line 229) /
  `writeToPTY` (line 285) are the write primitives.
- `Sources/Dreamux/Models/TabSession.swift:8` — per-tab object; owns the
  binding, tailer, and conversation model.
- `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift:82` —
  `TabContentView` is where the face switch wraps the terminal view.
- `Tools/claude` — shim already builds inline hooks JSON; add the
  `SessionStart` entry beside the existing Stop/Notification/flow entries.
- `Tools/dreamux-hook` — add `session-start` subcommand; dual-emit a
  `session-end` control OSC from the existing `flow` SessionEnd path;
  extend `notify` to dual-emit its structured control OSC. The
  OSC-on-`/dev/tty` transport and debug logging already exist.
- `Sources/Dreamux/Shell/ClaudePromptDriver.swift` — prior art for
  reliable PTY delivery (echo verification, file-backed long prompts);
  the composer reuses the lessons, not the code (it types into claude's
  TUI, not a booting shell).
- `FileTabKind.transcript` — existing route for opening subagent JSONLs in
  the static viewer.
