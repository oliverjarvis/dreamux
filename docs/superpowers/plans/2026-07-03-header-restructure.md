# Header Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the file-explorer toggle into the native window titlebar and replace the full-width hero band with a compact project header that sits above the terminal tabs, right of the Work-Items sidebar.

**Architecture:** All changes live in `Sources/Dreamux/Views/ContentView.swift`. The detail column of the `NavigationSplitView` changes from `VStack(heroBand, HSplitView(sidebar, mainPane))` to `HSplitView(sidebar, VStack(projectHeaderRow, mainPane))`, and a SwiftUI `.toolbar` item hosts the file-explorer toggle natively in the titlebar.

**Tech Stack:** SwiftUI (macOS), SwiftPM. Verification via `swift build`, `swift test`, and the in-process e2e screenshot harness (`Scripts/e2e/`).

**Spec:** `docs/superpowers/specs/2026-07-03-header-restructure-design.md`

## Global Constraints

- Single file change: `Sources/Dreamux/Views/ContentView.swift`. Do not touch `WorkspaceSidebar`, `ProjectsRail`, Bonsplit, `FileTreePanel`, or any `E2E*` file.
- **No `.keyboardShortcut` on the toolbar item** — toolbar-item shortcuts don't dispatch while the Ghostty terminal NSView is first responder. ⌥⌘E stays in `FileExplorerCommands` (View menu).
- Keep `.navigationTitle("")`, `.inspector`, `.focusedSceneValue(\.fileTreeVisible, ...)`, and all `.onAppear`/`.onChange` plumbing exactly as they are.
- `git add` only files named in each commit step (parallel sessions may touch the index).
- Line numbers below refer to the file as of commit `9782c77`; re-locate by content if the file has drifted.
- **Testing note:** this is a pure view-layout change with no unit-testable behavior surface, so tasks use compile + existing-test regression + an e2e screenshot instead of test-first TDD. No new unit tests are added.

---

### Task 1: File-explorer toggle in the titlebar

**Files:**
- Modify: `Sources/Dreamux/Views/ContentView.swift:150-170` (add `.toolbar`), `:304-319` (remove the hero-band button)

**Interfaces:**
- Consumes: `@State private var showFileTree: Bool` (already declared at `ContentView.swift:23`)
- Produces: a `ToolbarItem(placement: .primaryAction)` in the titlebar; the hero band no longer contains a button (Task 2 deletes the band entirely)

- [ ] **Step 1: Add the toolbar item**

In `ContentView.body`, directly after `.navigationTitle("")` (line 153), insert:

```swift
        // The file-explorer toggle lives in the native titlebar. It has no
        // `.keyboardShortcut` on purpose: a shortcut on a toolbar item isn't
        // dispatched while the Ghostty terminal NSView is first responder
        // (it just rings the bell) — ⌥⌘E lives in `FileExplorerCommands`
        // instead (see the comment on `focusedSceneValue` below).
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showFileTree.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(showFileTree ? Color.accentColor : Color.secondary)
                }
                .help("Toggle file explorer (⌥⌘E)")
            }
        }
```

- [ ] **Step 2: Remove the button from the hero band**

In `heroBand` (lines 304–319), delete the `Spacer(minLength: 8)` and the entire `Button { showFileTree.toggle() } ... .help("Toggle file explorer (⌥⌘E)")` block. Also update the `heroBand` doc comment (lines 273–277): drop the words "and the file-explorer toggle on the right".

- [ ] **Step 3: Build and run tests**

Run: `swift build 2>&1 | tail -5` — Expected: `Build complete!`
Run: `swift test 2>&1 | tail -5` — Expected: all tests pass (no test touches the toolbar).

- [ ] **Step 4: Commit**

```bash
git add Sources/Dreamux/Views/ContentView.swift
git commit -m "Move file-explorer toggle into the native titlebar"
```

---

### Task 2: Replace the hero band with a compact header above the tabs

**Files:**
- Modify: `Sources/Dreamux/Views/ContentView.swift:122-150` (detail column), `:273-337` (heroBand → projectHeaderRow)

**Interfaces:**
- Consumes: `currentProject: Project?` (`ContentView.swift:112`), `mainPane` (`:254-271`)
- Produces: `private var projectHeaderRow: some View` — compact avatar + name row

- [ ] **Step 1: Reshuffle the detail column**

Replace the detail closure body (lines 122–150, the comment + `VStack` wrapping `heroBand` and the `HSplitView`) with:

```swift
        } detail: {
            // The project rail stays the native, full-height split-view
            // sidebar. The Work-Items column reaches the top of the content
            // area; the compact project header sits right of it, above the
            // terminal tabs.
            HSplitView {
                WorkspaceSidebar(
                    store: store,
                    repoStore: repoStore,
                    runners: runners,
                    layout: layout,
                    sidebarMode: $sidebarMode,
                    docStore: docStore,
                    planRunner: planRunner,
                    planQueue: planQueue,
                    gateMergeWorkspaceID: $gateMergeWorkspaceID,
                    onOpenDoc: openFile
                )
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 380)

                VStack(spacing: 0) {
                    projectHeaderRow
                    mainPane
                }
                // maxHeight keeps the HSplitView vertically greedy in every
                // mode — without a height-flexible child the split collapses
                // under the header row.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
```

- [ ] **Step 2: Replace `heroBand` with `projectHeaderRow`**

Delete the `heroBand` property and its doc comment entirely (lines 273–337 region) and add in its place:

```swift
    /// Compact project identity — a small accent-gradient glyph and the
    /// project name — pinned above the terminal tabs, right of the
    /// Work-Items column. Replaces the old full-width hero band.
    private var projectHeaderRow: some View {
        let name = currentProject?.name ?? ""
        return HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 20, height: 20)

            Text(name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }
```

- [ ] **Step 3: Update the stale `.navigationTitle` comment**

Replace the comment at lines 151–153 ("The project identity lives in `heroBand` …") with:

```swift
        // The project identity lives in `projectHeaderRow` above the
        // terminal tabs, so the macOS titlebar title is blanked.
```

- [ ] **Step 4: Build and run tests**

Run: `swift build 2>&1 | tail -5` — Expected: `Build complete!`
Run: `swift test 2>&1 | tail -5` — Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Views/ContentView.swift
git commit -m "Replace hero band with compact project header above the tabs"
```

---

### Task 3: Visual verification and app boot

**Files:**
- No source changes. Uses `Scripts/make-app.sh`, `Scripts/e2e/PROTOCOL.md`.

**Interfaces:**
- Consumes: the built `Dreamux.app` bundle; the e2e `screenshot` command (in-process, no permissions).

- [ ] **Step 1: Build the app bundle**

Run: `./Scripts/make-app.sh` — Expected: exits 0, `Dreamux.app` refreshed at repo root.

- [ ] **Step 2: Sandboxed boot + screenshot**

Launch the binary with the e2e env (sandboxed projects root + state dir under the scratchpad, socket at a short `/tmp` path, seeded project so a window opens), send `{"cmd":"screenshot","path":"<scratchpad>/header.png"}` over the socket, then terminate the process. Follow `Scripts/e2e/PROTOCOL.md` — retry-connect for a couple of seconds after spawn.

Expected in the screenshot: titlebar shows the `sidebar.right` toggle at the trailing end; no blue hero band; compact avatar + name row above the ghostty tabs, starting right of the Work-Items sidebar; sidebar tiles reach the top. Read the screenshot and verify each point; fix and re-shoot if anything is off.

- [ ] **Step 3: Verify the toggle works**

Over the same socket session (before terminating): send `{"cmd":"setFileTree","visible":true}` (see `Scripts/e2e/PROTOCOL.md`), screenshot again, confirm the inspector opened and the toolbar icon is accent-tinted.

- [ ] **Step 4: Boot the app for the user**

Run: `open <repo>/Dreamux.app` (no e2e env — real projects). Expected: window opens with the new chrome.
