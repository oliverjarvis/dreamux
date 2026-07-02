# Universal File Viewers

**Date:** 2026-07-02
**Status:** Approved

## Problem

The file tree and editor tabs (see
`docs/superpowers/plans/2026-07-01-cross-repo-file-tree-editor.md`) open
every file into Monaco or, failing that, an "unsupported" placeholder.
Today that means:

- Syntax highlighting for only ~20 hardcoded extensions
  (`FileEditorTabSession.language(forExtension:)`); everything else
  renders as plain text.
- No markdown rendering — plans and specs read as raw text.
- No image, video, audio, PDF, or office-document viewing at all; any
  non-UTF-8 file hits the placeholder.
- No tabular view for CSV/TSV.
- A blanket 2 MB cap that makes no sense for media.

The Plans & Specs work
(`2026-07-02-plans-specs-orchestration-design.md`) depends on rendered
markdown, so this spec lands first.

## Decision

Native-first hybrid: Monaco stays the code/text editor; each non-code
type gets the native macOS view built for it. One new SPM dependency
(swift-markdown-ui) for markdown rendering.

Approaches considered:

- **Native-first hybrid (chosen):** AVKit, PDFKit, Quick Look,
  NSTableView, NSImageView per type. Matches the standing preference
  for native macOS controls, keeps the dependency-lean stance (one
  pure-Swift SPM package), and every viewer follows the existing
  `NSViewRepresentable` + tab-session pattern.
- **Web-first:** vendor markdown-it, SheetJS, PapaParse next to Monaco
  in the WKWebView stack. One rendering surface, but megabytes of
  vendored JS, hand-rolled HTML theming, and non-native feel. Rejected.
- **Quick Look for everything non-code:** simplest, but no CSV tables,
  no markdown raw/rendered toggle, weak zoom control. Rejected.

## Design

### 1. Classification — `FileTabKind`

A new enum in `Models/FileEditorTabSession.swift` (or a sibling file)
with a static, unit-testable classifier keyed on `UTType` (falling back
to extension):

- `.code` — everything text that isn't one of the below (includes TOML,
  JSON, YAML, source files, plain text)
- `.markdown` — `md`, `markdown`, `mdx`
- `.image` — png, jpeg, gif, heic, webp, tiff, bmp, svg
  (`UTType.image` conformance, svg special-cased)
- `.video` / `.audio` — `UTType.audiovisualContent` conformance
- `.pdf`
- `.officePreview` — xlsx, xls, docx, doc, pptx, ppt, numbers, pages,
  key
- `.tabular` — csv, tsv
- `.unsupported` — binary/unknown

`FileEditorTabSession` gains a `kind: FileTabKind` decided at open
time. The one-tab-one-map invariant in `WorkspaceSession` is
unchanged — all of these remain entries in `fileTabSessions`.

The 2 MB text cap applies only to Monaco-backed kinds (`.code`,
`.markdown` raw mode, `.tabular` text mode). Media kinds load from disk
via their native views with no cap.

### 2. Syntax highlighting — full Monaco registry

- Replace the hardcoded ~20-entry Swift extension map: Swift passes the
  file's extension (not a language id) to the editor, and
  `editor-boot.js` resolves it against `monaco.languages.getLanguages()`
  at open time, falling back to `plaintext`. Coverage is every language
  Monaco bundles (~80); `FileEditorTabSession.language(forExtension:)`
  is deleted.
- TOML is not in Monaco's built-ins: register a small custom Monarch
  tokenizer (`toml` language id) in `editor-boot.js` covering tables,
  keys, strings, numbers, booleans, dates, and comments. `.toml` maps
  to it.

### 3. Markdown — rendered by default, Raw toggle

- New dependency: `swift-markdown-ui` (MarkdownUI) in `Package.swift`.
  Chosen over `AttributedString(markdown:)` (no tables/task lists) and
  a vendored JS renderer (theming + bundle weight) — same reasoning the
  2026-06-12 spec approved.
- Markdown tabs open in **Rendered** mode: a SwiftUI `Markdown` view in
  a scroll view, GitHub-flavored (tables, fenced code, task-list
  checkboxes — required by plan files), following system appearance.
- A `Rendered | Raw` toggle in the tab's toolbar switches to the
  existing Monaco editor for the same session (same buffer, same save
  path, same dirty tracking). Rendered mode is read-only; edits happen
  in Raw. Toggling back re-renders from the current buffer, not disk.
- Mode is per-tab state on `FileEditorTabSession`, defaulting to
  Rendered.

### 4. Images — native zoomable viewer

`Views/ImageViewer.swift`: `NSViewRepresentable` wrapping an
`NSScrollView` with `allowsMagnification` (0.1×–20×) around an
`NSImageView`. Pinch and scroll-wheel zoom, double-click toggles
fit/100%, toolbar buttons for Fit / Actual Size and a zoom readout.
SVG loads via `NSImage` (WebKit fallback is out of scope).

### 5. Video & audio — AVKit

`Views/MediaPlayerView.swift`: `AVPlayerView` with native controls
(scrub, volume, picture-in-picture off). Streams from the worktree
file URL — no size cap. Audio files use the same view (compact
controls-only height is fine v1).

### 6. PDF — PDFKit

`PDFView` with `autoScales`, standard find/zoom behavior for free.

### 7. Office documents — Quick Look

`Views/QuickLookPreview.swift`: `QLPreviewView` (Quartz framework)
rendering xlsx/docx/pptx/etc read-only — real sheet cells, paginated
documents, slide previews. No editing: an editable grid is explicitly
out of scope. Files that Quick Look cannot preview fall through to the
`.unsupported` placeholder.

### 8. CSV / TSV — native table

- A small RFC-4180 parser (static, unit-testable: quoted fields,
  escaped quotes, embedded newlines/delimiters; TSV = tab delimiter).
- `Views/CSVTableView.swift`: virtualized `NSTableView` via
  `NSViewRepresentable`. First row as header (heuristic: all-text row
  followed by rows that parse differently; when unsure, show it as
  header with a toggle), click-to-sort columns, row-number gutter.
- Row cap (10k rows parsed) with a truncation banner naming the total.
- A `Table | Text` toggle drops to Monaco for editing (same
  buffer/save/dirty semantics as markdown's Raw mode). Table mode is
  read-only v1.
- Parse failures (mismatched quotes, not actually tabular) fall back to
  Monaco text mode with a notice.

### 9. Dispatch & wiring

`FileEditorView` in `Views/WorkspaceTerminalContainer.swift` becomes a
dispatcher switching on `session.kind` to the per-kind views above.
Only Monaco-backed modes can be dirty; `FileTabDirtyObserver` behavior
is unchanged. The placeholder gains an "Open with Quick Look" attempt
button as a last resort for `.unsupported` files.

## Error handling

- Unreadable/undecodable files keep today's placeholder with the
  reason.
- A file deleted on disk while its tab is open keeps the buffer alive
  and marks the tab; save recreates the file (existing atomic-write
  path).
- Media that fails to load (corrupt image, unplayable codec) shows the
  placeholder with the underlying error string.
- Oversized text files (over cap) get the placeholder with the size and
  a Reveal in Finder button.

## Testing

- Unit: `FileTabKind` classifier (extension and UTType cases), CSV
  parser (RFC-4180 edge cases), header heuristic, TOML tokenizer smoke
  test via the JS bridge if practical (else covered by e2e).
- E2E: extend the automation server state dump with each file tab's
  `kind` and mode; scenarios open fixture files of each type from the
  file tree and assert kind, and toggle markdown Rendered↔Raw and CSV
  Table↔Text.

## Out of scope

- Editable spreadsheets / grid editing of any kind
- Image editing, cropping, annotation
- Diff views
- In-viewer search (beyond what PDFKit/Monaco give natively)
- Jupyter notebooks, custom binary formats
