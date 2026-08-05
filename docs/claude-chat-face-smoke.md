# Claude chat face — manual smoke checklist

**Re-run this whole checklist whenever the pinned Claude Code version
changes.** The chat face reads a live `claude` TUI through a set of
keystroke recipes and hook/transcript signals that assume how that
specific Claude Code build lays out its dialogs and writes its
transcript. **`Sources/Dreamux/Shell/PromptKeystrokeRecipes.swift` is
the file under test** — if a Claude Code upgrade moves an option row,
renames the AskUserQuestion shape, or changes the permission-prompt
wording, these recipes are what break, and this checklist is how we
catch it before a user does. `swift test` covers the recipes and the
transcript parser in isolation; this list covers the parts only a real
`claude` process exercises.

Run each step against a real `claude` in a Dreamux terminal tab (not
`Scripts/e2e/fake-claude`, which is deterministic and can't surface a
recipe regression). Check the box only when the observed behavior
matches.

- [ ] **1. Session binds and the face auto-flips.** Run `claude` in a
  workspace's terminal tab. The tab auto-flips from Terminal to **Chat**
  on the first bind, the face toggle pill appears, and the status chip
  tracks the session: **working** while a turn is in flight, **waiting**
  when it asks for you. Flipping back to Terminal and re-flipping to Chat
  keeps the same conversation.

- [ ] **2. Composer prompt lands verbatim and the reply streams in.**
  Type a prompt into the chat composer and send. Flip to **Terminal** to
  confirm the exact text landed in claude's input line (no dropped or
  reordered characters, no early submit). Flip back to **Chat**; the
  assistant's response streams into the transcript as it arrives.

- [ ] **3. AskUserQuestion — single select.** Get claude to ask a
  single-select question (e.g. ask it to confirm an approach with a
  couple of options). The options render as a banner in the chat face.
  Clicking an option selects **that** option in the TUI (verify in
  Terminal) and the turn resumes.

- [ ] **4. AskUserQuestion — multi-select.** Trigger a `multiSelect`
  question. Each option toggles independently, and **Submit** sends
  exactly the toggled set — no more, no fewer — to the TUI.

- [ ] **5. Other / free text.** On a question that offers an **Other**
  row, choosing it and typing free text lands that text verbatim as the
  answer in the TUI.

- [ ] **6. Permission prompt.** Trigger a tool-permission prompt (e.g.
  let claude try to run a command that needs approval). The chat face
  shows the permission banner, and **"Respond in terminal"** flips the
  tab to Terminal so you can answer the prompt where it lives (these
  prompts arrive as Notification-hook messages, never in the transcript).

- [ ] **7. Interrupt stops a turn.** With a turn in flight, the chat
  face's **interrupt/stop** button (ESC to the TUI) halts it — claude
  stops generating and returns to the prompt, and the status chip leaves
  **working**.

- [ ] **8. Rebind across session boundaries.** `/clear` inside claude,
  `claude --resume`, and quit-then-rerun `claude` in the same tab each
  **rebind** the face: the status chip and transcript re-attach to the
  new/resumed session every time, with no stale conversation left over
  from the previous one.

- [ ] **9. Hard kill is detected.** `kill -9` the `claude` process from
  another shell. Within ~2s the registry liveness backstop notices the
  session is gone and the face shows **Session ended** (the toggle pill
  stays so you can flip back to Terminal).

## Scripted e2e replay (deterministic, fake-claude)

Deferred at merge time (2026-07-10) because a live Dreamux instance held
focus and the emit socket — **this replay has not yet been observed
running end-to-end**. Run it once, with no Dreamux instance open; it
drives bind → auto-flip → question banner → answer → idle without a real
`claude`.

```sh
REPO=/Users/olliejarvis/Development/clayspace
SHOTS=/tmp/chat-face-shots; mkdir -p "$SHOTS"
SANDBOX="$(mktemp -d)"; SOCK=/tmp/dreamux-chatface.sock; SESSIONS="$SANDBOX/sessions"
mkdir -p "$SANDBOX/projects/demo" "$SANDBOX/state" "$SESSIONS"

"$REPO/Scripts/make-app.sh" debug           # build the bundle

DREAMUX_E2E_SOCKET="$SOCK" DREAMUX_E2E_AUTOOPEN=demo \
DREAMUX_PROJECTS_ROOT="$SANDBOX/projects" DREAMUX_STATE_DIR="$SANDBOX/state" \
DREAMUX_SESSIONS_DIR="$SESSIONS" \
  "$REPO/Dreamux.app/Contents/MacOS/Dreamux" -ApplePersistenceIgnoreState YES &

# Over the socket (see Scripts/e2e/PROTOCOL.md — newline-delimited JSON):
#  1. poll {"cmd":"state"} until activeProject.name == "demo"
#  2. {"cmd":"createFeature","name":"chatface","repos":[]}
#     (or openMainWorkspace); then setSidebarMode workspace so the pane mounts
#  3. {"cmd":"sendTerminalText","text":"'"$REPO"'/Scripts/e2e/fake-claude","submit":true}
#  4. poll {"cmd":"chatFaceState"} until
#        phase=="waitingForUser" && pendingQuestion==true && face=="chat"
#  5. {"cmd":"screenshot","path":"'"$SHOTS"'/chat-face-question.png"}
#  6. answer: {"cmd":"sendTerminalText","text":"Manual toggle","submit":true}
#        (types into fake-claude's stdin, i.e. the tab's PTY)
#  7. poll {"cmd":"chatFaceState"} until phase=="idle" && items grew (>=6)
#  8. {"cmd":"screenshot","path":"'"$SHOTS"'/chat-face-idle.png"}
#  9. {"cmd":"quit"}
```

The Overview tab is selected by default and there is no tab-selection
e2e command, so the screenshots document window chrome; `chatFaceState`
(which falls back to the shell `TabSession`) is the authoritative
assertion.

## Diagnosing an unexplained desktop banner

Dreamux posts every banner through `UNUserNotificationCenter` and ships
no `osascript` notification code, so a banner that looks like it came
from Script Editor was posted by the harness, not by Dreamux. To find
out which:

1. Launch Dreamux with `DREAMUX_NOTIFY_DEBUG=1` in its environment.
2. Reproduce the banner.
3. Read the provenance log:

   ```sh
   log show --predicate 'subsystem == "com.dreamux.Dreamux"' --info --last 10m \
     | grep NotificationProvenance
   ```

   A line for the banner means it arrived as a terminal escape and
   Dreamux saw it. No line means the harness posted it out-of-band —
   check for an `osascript` process under the agent:

   ```sh
   pgrep -lf osascript
   ```
