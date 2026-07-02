# Universal File Viewers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every file opened from the file tree renders with the right native viewer — full-coverage syntax highlighting, rendered markdown with a raw toggle, zoomable images, video/audio, PDF, office previews, and CSV tables.

**Architecture:** A `FileTabKind` classifier (extension/UTType → kind) decided at tab-open time drives a dispatcher in `FileEditorView`. Monaco remains the code editor (language now resolved by Monaco itself from the file extension, plus a custom TOML tokenizer); each non-code kind gets its own native view (MarkdownUI, NSScrollView+NSImageView, AVKit, PDFKit, Quick Look, NSTableView). All viewers hang off the existing `FileEditorTabSession` — the one-tab-one-map invariant in `WorkspaceSession` is untouched.

**Tech Stack:** Swift 6 / SwiftUI + AppKit interop (`NSViewRepresentable`), Monaco (vendored web assets over `app-monaco://`), swift-markdown-ui (new SPM dependency), AVKit, PDFKit, Quartz (QLPreviewView), XCTest.

**Spec:** `docs/superpowers/specs/2026-07-02-universal-file-viewers-design.md` — read it before starting.

## Global Constraints

- macOS 14 floor, Swift 6 tools (`// swift-tools-version: 6.0`), strict concurrency — stores/sessions are `@MainActor @Observable`.
- The ONLY new package dependency allowed is `swift-markdown-ui`. Everything else must be system frameworks or existing deps.
- A Bonsplit `TabID` maps to exactly one of the three session maps in `WorkspaceSession` (terminal / web / file). Do not add a fourth map — all viewers are file tabs.
- `contentViewLifecycle: .keepAllAlive` is non-negotiable; never change `BonsplitConfiguration`.
- The 2 MB text cap (`FileEditorTabSession.maxBytes`) applies only to Monaco-backed text; media kinds must not read file contents into memory.
- E2E code must stay inert unless `DREAMUX_E2E_SOCKET` is set. Keep `scripts/e2e/PROTOCOL.md` in lockstep with `E2ECommands.swift`.
- Run `swift build` and `swift test` from the repo root; both must pass at the end of every task.
- Commit after every task (and after test/implementation step pairs where the steps say so). Never commit unrelated files — stage by name.

---

### Task 1: `FileTabKind` classifier

**Files:**
- Create: `Sources/Dreamux/Models/FileTabKind.swift`
- Test: `Tests/DreamuxTests/FileTabKindTests.swift`

**Interfaces:**
- Consumes: nothing (leaf).
- Produces: `enum FileTabKind: String, Sendable` with cases `code, markdown, image, video, audio, pdf, officePreview, tabular`; `static func kind(forPathExtension:) -> FileTabKind`; `var tabIcon: String`; `var isMonacoBacked: Bool`. Later tasks switch on exactly these case names.

- [x] **Step 1: Write the failing test**

Create `Tests/DreamuxTests/FileTabKindTests.swift`:

```swift
import XCTest
@testable import Dreamux

final class FileTabKindTests: XCTestCase {
    func testExplicitExtensions() {
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "md"), .markdown)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "MDX"), .markdown)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "csv"), .tabular)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "tsv"), .tabular)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "pdf"), .pdf)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "xlsx"), .officePreview)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "docx"), .officePreview)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "numbers"), .officePreview)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "svg"), .image)
    }

    func testUTTypeConformanceFallback() {
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "png"), .image)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "heic"), .image)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "webp"), .image)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "mov"), .video)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "mp4"), .video)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "mp3"), .audio)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "wav"), .audio)
    }

    func testEverythingElseIsCode() {
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "swift"), .code)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "toml"), .code)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "json"), .code)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: ""), .code)
        XCTAssertEqual(FileTabKind.kind(forPathExtension: "zzznotreal"), .code)
    }

    func testMonacoBackedKinds() {
        XCTAssertTrue(FileTabKind.code.isMonacoBacked)
        XCTAssertTrue(FileTabKind.markdown.isMonacoBacked)
        XCTAssertTrue(FileTabKind.tabular.isMonacoBacked)
        XCTAssertFalse(FileTabKind.image.isMonacoBacked)
        XCTAssertFalse(FileTabKind.officePreview.isMonacoBacked)
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter FileTabKindTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'FileTabKind' in scope` (compile error counts as the failing state).

- [x] **Step 3: Write minimal implementation**

Create `Sources/Dreamux/Models/FileTabKind.swift`:

```swift
import Foundation
import UniformTypeIdentifiers

/// How a file tab renders its content. Decided once at open time from
/// the file's extension (with UTType conformance as fallback). Whether
/// the file is *actually* displayable (binary/oversized text, missing
/// media) is a separate, per-kind check in `FileEditorTabSession`.
enum FileTabKind: String, Sendable {
    case code           // Monaco editor
    case markdown       // rendered MarkdownUI with a Raw (Monaco) toggle
    case image          // native zoomable image viewer
    case video          // AVPlayerView
    case audio          // AVPlayerView
    case pdf            // PDFView
    case officePreview  // QLPreviewView (xlsx, docx, keynote, …), read-only
    case tabular        // CSV/TSV table with a Text (Monaco) toggle

    static func kind(forPathExtension ext: String) -> FileTabKind {
        let lower = ext.lowercased()
        switch lower {
        case "md", "markdown", "mdx":
            return .markdown
        case "csv", "tsv":
            return .tabular
        case "pdf":
            return .pdf
        case "xlsx", "xls", "docx", "doc", "pptx", "ppt",
             "numbers", "pages", "key":
            return .officePreview
        case "svg":
            // UTType reports svg as an image, but be explicit: NSImage
            // renders it natively and we never want Monaco XML mode.
            return .image
        case "":
            return .code
        default:
            break
        }
        guard let type = UTType(filenameExtension: lower) else { return .code }
        if type.conforms(to: .image) { return .image }
        // Order matters: .audio also conforms to .audiovisualContent.
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .pdf) { return .pdf }
        return .code
    }

    /// SF Symbol for the Bonsplit tab chip.
    var tabIcon: String {
        switch self {
        case .code: return "doc.text"
        case .markdown: return "doc.richtext"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.text.image"
        case .officePreview: return "tablecells"
        case .tabular: return "tablecells"
        }
    }

    /// Kinds whose content lives in (or can drop into) the Monaco
    /// editor — these are the only kinds that read text and can be
    /// dirty/saved.
    var isMonacoBacked: Bool {
        switch self {
        case .code, .markdown, .tabular: return true
        case .image, .video, .audio, .pdf, .officePreview: return false
        }
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --filter FileTabKindTests 2>&1 | tail -5`
Expected: PASS (4 tests).

- [x] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/FileTabKind.swift Tests/DreamuxTests/FileTabKindTests.swift
git commit -m "Add FileTabKind classifier for per-type file viewers"
```

---

### Task 2: Monaco resolves language from extension; expose `__getValue`

**Files:**
- Modify: `Sources/Dreamux/Resources/Monaco/editor-boot.js`
- Modify: `Sources/Dreamux/Models/FileEditorTabSession.swift` (delete `language(forExtension:)`, pass extension in `handleReady`)
- Test: `Tests/DreamuxTests/FileEditorTabSessionTests.swift` (delete `testLanguageForExtension`)

**Interfaces:**
- Consumes: nothing new.
- Produces: JS `window.__setContents(text, ext, theme)` — second parameter is now the **file extension** (e.g. `"swift"`, `""`), not a language id; JS `window.__getValue()` returning the editor's current text (used by Task 5's `refreshCurrentTextFromEditor`). Swift: `FileEditorTabSession.language(forExtension:)` no longer exists.

- [x] **Step 1: Delete the obsolete Swift test**

In `Tests/DreamuxTests/FileEditorTabSessionTests.swift`, delete the whole `testLanguageForExtension` method (lines 10–15). Coverage for classification now lives in `FileTabKindTests`; language resolution moves into Monaco itself where the registry lives.

- [x] **Step 2: Rewrite `editor-boot.js` language handling**

In `Sources/Dreamux/Resources/Monaco/editor-boot.js`, inside the `require(['vs/editor/editor.main'], function () { … })` callback, add a resolver above `window.__setContents` and change `__setContents` to take an extension. The full callback becomes:

```js
require(['vs/editor/editor.main'], function () {
  var editor = monaco.editor.create(document.getElementById('container'), {
    value: '',
    language: 'plaintext',
    theme: 'vs',
    automaticLayout: true,
    minimap: { enabled: true }
  });

  editor.onDidChangeModelContent(function () {
    post({ type: 'dirty', value: true });
  });

  editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, function () {
    post({ type: 'save', text: editor.getValue() });
  });

  // Resolve a file extension against every language Monaco knows
  // (built-ins plus anything registered above). Case-insensitive;
  // unknown extensions fall back to plaintext.
  function languageForExtension(ext) {
    if (!ext) return 'plaintext';
    var dot = '.' + String(ext).toLowerCase();
    var langs = monaco.languages.getLanguages();
    for (var i = 0; i < langs.length; i++) {
      var exts = langs[i].extensions || [];
      for (var j = 0; j < exts.length; j++) {
        if (exts[j].toLowerCase() === dot) return langs[i].id;
      }
    }
    return 'plaintext';
  }

  // Swift → editor: install a file's contents/extension/theme.
  window.__setContents = function (text, ext, theme) {
    monaco.editor.setTheme(theme);
    editor.setModel(monaco.editor.createModel(text, languageForExtension(ext)));
    post({ type: 'dirty', value: false });
  };

  // Editor → Swift pull: the rendered-markdown toggle reads the live
  // buffer without waiting for a save.
  window.__getValue = function () { return editor.getValue(); };

  post({ type: 'ready' });
});
```

- [x] **Step 3: Update `handleReady` and delete `language(forExtension:)`**

In `Sources/Dreamux/Models/FileEditorTabSession.swift`:

Delete the whole `language(forExtension:)` static method (the `/// Monaco language id for a file extension.` block).

Replace `handleReady()` with:

```swift
    private func handleReady() {
        let js = "window.__setContents("
            + "\(Self.jsString(contents)), "
            + "\(Self.jsString(fileURL.pathExtension)), "
            + "\(Self.jsString(Self.currentTheme())));"
        _webView?.evaluateJavaScript(js)
    }
```

(`contents` is still the stored property at this point; Task 5 renames it.)

- [x] **Step 4: Build and run the full test suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build succeeds; all tests pass (the deleted test no longer runs; nothing else referenced `language(forExtension:)`).

- [x] **Step 5: Commit**

```bash
git add Sources/Dreamux/Resources/Monaco/editor-boot.js Sources/Dreamux/Models/FileEditorTabSession.swift Tests/DreamuxTests/FileEditorTabSessionTests.swift
git commit -m "Resolve Monaco language from extension via the language registry"
```

---

### Task 3: TOML language for Monaco

**Files:**
- Modify: `Sources/Dreamux/Resources/Monaco/editor-boot.js`

**Interfaces:**
- Consumes: Task 2's `languageForExtension` (picks up the registration automatically because it walks `monaco.languages.getLanguages()`).
- Produces: a registered `toml` Monaco language with tokenizer + comment config; `.toml` files highlight.

- [x] **Step 1: Register the language + Monarch tokenizer**

In `Sources/Dreamux/Resources/Monaco/editor-boot.js`, inside the `require([...])` callback, immediately **before** `var editor = monaco.editor.create(...)`, insert:

```js
  // Monaco ships ~80 languages but not TOML; register a small Monarch
  // tokenizer so run.toml / Cargo.toml / pyproject.toml highlight.
  monaco.languages.register({ id: 'toml', extensions: ['.toml'] });
  monaco.languages.setLanguageConfiguration('toml', {
    comments: { lineComment: '#' },
    brackets: [['[', ']'], ['{', '}']],
  });
  monaco.languages.setMonarchTokensProvider('toml', {
    tokenizer: {
      root: [
        [/^\s*\[\[?[^\]]*\]\]?/, 'keyword'],            // [table] / [[array of tables]]
        [/^\s*[A-Za-z0-9_"'.-]+(?=\s*=)/, 'variable'],  // key =
        [/#.*$/, 'comment'],
        [/"""/, 'string', '@tripleString'],
        [/"/, 'string', '@string'],
        [/'''/, 'string', '@tripleLiteral'],
        [/'/, 'string', '@literalString'],
        [/\b(true|false)\b/, 'constant'],
        // Dates before numbers so 2026-07-02 isn't three numbers.
        [/\d{4}-\d{2}-\d{2}([Tt ]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})?)?/, 'number'],
        [/\d{2}:\d{2}:\d{2}(\.\d+)?/, 'number'],
        [/[+-]?(0x[0-9A-Fa-f_]+|0o[0-7_]+|0b[01_]+|inf|nan|\d[\d_]*(\.[\d_]+)?([eE][+-]?\d+)?)/, 'number'],
        [/[,={}\[\]]/, 'delimiter'],
      ],
      string: [
        [/[^"\\]+/, 'string'],
        [/\\./, 'string.escape'],
        [/"/, 'string', '@pop'],
      ],
      tripleString: [
        [/"""/, 'string', '@pop'],
        [/\\./, 'string.escape'],
        [/./, 'string'],
      ],
      literalString: [
        [/[^']+/, 'string'],
        [/'/, 'string', '@pop'],
      ],
      tripleLiteral: [
        [/'''/, 'string', '@pop'],
        [/./, 'string'],
      ],
    },
  });
```

- [x] **Step 2: Verify by launching the app**

Run: `swift build 2>&1 | tail -3`
Expected: build succeeds.

Then launch (`swift run Dreamux` or the usual dev launch), open any feature's file tree (⌥⌘E), open `.dreamux/run.toml` or any `*.toml` file, and confirm: table headers, keys, strings, and comments are colorized (not uniform plaintext), and `#` comments are dimmed. There is no JS unit-test harness for the vendored Monaco bundle — the e2e state dump can't see token colors, so this visual check plus the resolver test in Task 10's e2e scenario is the verification.

- [x] **Step 3: Commit**

```bash
git add Sources/Dreamux/Resources/Monaco/editor-boot.js
git commit -m "Register TOML Monarch tokenizer in Monaco"
```

---

### Task 4: `CSVTable` parser

**Files:**
- Create: `Sources/Dreamux/Models/CSVTable.swift`
- Test: `Tests/DreamuxTests/CSVTableTests.swift`

**Interfaces:**
- Consumes: nothing (pure).
- Produces:
  - `struct CSVTable: Equatable { var header: [String]?; var rows: [[String]]; var totalDataRows: Int; var isTruncated: Bool }`
  - `static func parseRecords(_ text: String, delimiter: Character) -> [[String]]?` — nil on unterminated quote.
  - `static func looksLikeHeader(_ records: [[String]]) -> Bool`
  - `static func table(from text: String, delimiter: Character, treatFirstRowAsHeader: Bool?, displayLimit: Int) -> CSVTable?` — nil when parsing fails or the content isn't tabular (fewer than 2 records AND fewer than 2 columns). `treatFirstRowAsHeader: nil` means "use the heuristic".

- [x] **Step 1: Write the failing tests**

Create `Tests/DreamuxTests/CSVTableTests.swift`:

```swift
import XCTest
@testable import Dreamux

final class CSVTableTests: XCTestCase {
    // MARK: - parseRecords

    func testSimpleRecords() {
        XCTAssertEqual(
            CSVTable.parseRecords("a,b,c\n1,2,3\n", delimiter: ","),
            [["a", "b", "c"], ["1", "2", "3"]]
        )
    }

    func testQuotedFieldWithDelimiterNewlineAndEscapedQuote() {
        let text = "name,notes\n\"Doe, Jane\",\"line1\nline2 \"\"quoted\"\"\"\n"
        XCTAssertEqual(
            CSVTable.parseRecords(text, delimiter: ","),
            [["name", "notes"], ["Doe, Jane", "line1\nline2 \"quoted\""]]
        )
    }

    func testCRLFAndFinalLineWithoutNewline() {
        XCTAssertEqual(
            CSVTable.parseRecords("a,b\r\n1,2\r\n3,4", delimiter: ","),
            [["a", "b"], ["1", "2"], ["3", "4"]]
        )
    }

    func testTabDelimiter() {
        XCTAssertEqual(
            CSVTable.parseRecords("a\tb\n1\t2\n", delimiter: "\t"),
            [["a", "b"], ["1", "2"]]
        )
    }

    func testUnterminatedQuoteFails() {
        XCTAssertNil(CSVTable.parseRecords("a,\"broken\n1,2\n", delimiter: ","))
    }

    func testEmptyFieldsSurvive() {
        XCTAssertEqual(
            CSVTable.parseRecords("a,,c\n,,\n", delimiter: ","),
            [["a", "", "c"], ["", "", ""]]
        )
    }

    // MARK: - Header heuristic

    func testHeaderDetectedWhenFirstRowTextAndDataNumeric() {
        let records = [["name", "age"], ["jane", "40"], ["joe", "31"]]
        XCTAssertTrue(CSVTable.looksLikeHeader(records))
    }

    func testNoHeaderWhenFirstRowNumericToo() {
        let records = [["1", "2"], ["3", "4"]]
        XCTAssertFalse(CSVTable.looksLikeHeader(records))
    }

    // MARK: - table(from:)

    func testTableRespectsDisplayLimitAndReportsTruncation() throws {
        var lines = ["col"]
        for i in 0..<50 { lines.append("\(i)") }
        let table = try XCTUnwrap(CSVTable.table(
            from: lines.joined(separator: "\n"),
            delimiter: ",", treatFirstRowAsHeader: nil, displayLimit: 10
        ))
        XCTAssertEqual(table.header, ["col"])
        XCTAssertEqual(table.rows.count, 10)
        XCTAssertEqual(table.totalDataRows, 50)
        XCTAssertTrue(table.isTruncated)
    }

    func testTablePadsRaggedRows() throws {
        let table = try XCTUnwrap(CSVTable.table(
            from: "a,b,c\n1,2\n", delimiter: ",",
            treatFirstRowAsHeader: true, displayLimit: 1000
        ))
        XCTAssertEqual(table.rows, [["1", "2", ""]])
    }

    func testNonTabularContentReturnsNil() {
        // One record, one column — a prose paragraph, not a table.
        XCTAssertNil(CSVTable.table(
            from: "just a sentence with no commas",
            delimiter: ",", treatFirstRowAsHeader: nil, displayLimit: 1000
        ))
    }

    func testExplicitHeaderOverrideBeatsHeuristic() throws {
        let table = try XCTUnwrap(CSVTable.table(
            from: "1,2\n3,4\n", delimiter: ",",
            treatFirstRowAsHeader: true, displayLimit: 1000
        ))
        XCTAssertEqual(table.header, ["1", "2"])
        XCTAssertEqual(table.rows, [["3", "4"]])
    }
}
```

- [x] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CSVTableTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'CSVTable' in scope`.

- [x] **Step 3: Write the implementation**

Create `Sources/Dreamux/Models/CSVTable.swift`:

```swift
import Foundation

/// Parsed tabular data for the CSV/TSV table viewer. Parsing is a
/// strict-enough RFC 4180 state machine: quoted fields may contain the
/// delimiter, newlines, and escaped quotes (`""`). Input is already
/// bounded by the editor's 2 MB text cap, so whole-file parsing is fine.
struct CSVTable: Equatable {
    /// Column titles when the first record is (or is forced to be) a
    /// header; nil renders numbered columns.
    var header: [String]?
    /// Data records, padded to a uniform column count, capped at the
    /// display limit.
    var rows: [[String]]
    /// Count of data records before capping.
    var totalDataRows: Int
    var isTruncated: Bool

    /// RFC 4180 records, or nil when a quoted field never terminates.
    static func parseRecords(_ text: String, delimiter: Character) -> [[String]]? {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var i = text.startIndex

        while i < text.endIndex {
            let ch = text[i]
            if inQuotes {
                if ch == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")   // escaped quote
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"" where field.isEmpty:
                    inQuotes = true
                case delimiter:
                    record.append(field); field = ""
                case "\r":
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\n" { i = next }
                    record.append(field); field = ""
                    records.append(record); record = []
                case "\n":
                    record.append(field); field = ""
                    records.append(record); record = []
                default:
                    field.append(ch)
                }
            }
            i = text.index(after: i)
        }
        if inQuotes { return nil }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }

    /// True when the first record reads like column titles: every cell
    /// non-empty and non-numeric, while at least one later cell is
    /// numeric. Deliberately conservative — the view offers a manual
    /// override toggle.
    static func looksLikeHeader(_ records: [[String]]) -> Bool {
        guard let first = records.first, records.count > 1 else { return false }
        let firstIsTextOnly = first.allSatisfy { !$0.isEmpty && Double($0) == nil }
        guard firstIsTextOnly else { return false }
        return records.dropFirst().contains { row in
            row.contains { Double($0) != nil }
        }
    }

    static func table(
        from text: String,
        delimiter: Character,
        treatFirstRowAsHeader: Bool?,
        displayLimit: Int
    ) -> CSVTable? {
        guard var records = parseRecords(text, delimiter: delimiter) else { return nil }
        records.removeAll { $0 == [""] }   // blank lines
        let columnCount = records.map(\.count).max() ?? 0
        // Not tabular: nothing that reads as rows-and-columns.
        guard records.count >= 2 || columnCount >= 2 else { return nil }

        let hasHeader = treatFirstRowAsHeader ?? looksLikeHeader(records)
        let header = hasHeader ? pad(records.removeFirst(), to: columnCount) : nil
        let total = records.count
        let capped = records.prefix(displayLimit).map { pad($0, to: columnCount) }
        return CSVTable(
            header: header,
            rows: Array(capped),
            totalDataRows: total,
            isTruncated: total > displayLimit
        )
    }

    private static func pad(_ row: [String], to count: Int) -> [String] {
        row + Array(repeating: "", count: max(0, count - row.count))
    }
}
```

- [x] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CSVTableTests 2>&1 | tail -5`
Expected: PASS (12 tests).

- [x] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/CSVTable.swift Tests/DreamuxTests/CSVTableTests.swift
git commit -m "Add RFC 4180 CSVTable parser with header heuristic"
```

---

### Task 5: Session gains kind, view mode, and live text

**Files:**
- Modify: `Sources/Dreamux/Models/FileEditorTabSession.swift`
- Modify: `Sources/Dreamux/Models/WorkspaceSession.swift` (tab icon per kind in `openFileTab`)
- Test: `Tests/DreamuxTests/FileEditorTabSessionTests.swift`

**Interfaces:**
- Consumes: Task 1's `FileTabKind`; Task 2's `window.__getValue()`.
- Produces (used by every view task):
  - `let kind: FileTabKind`
  - `enum FileTabViewMode: String { case rendered, source, table }`
  - `var viewMode: FileTabViewMode` (markdown defaults `.rendered`, tabular `.table`, else `.source`)
  - `private(set) var currentText: String` (disk contents at init; updated on save and by the pull below)
  - `func refreshCurrentTextFromEditor()` — pulls the live Monaco buffer into `currentText` (no-op when the webview was never built)
  - `var useQuickLookFallback: Bool` (placeholder's "Try Quick Look" flag)
  - `nonisolated static func defaultViewMode(for kind: FileTabKind) -> FileTabViewMode`
  - `isSupported` semantics: Monaco-backed kinds → decodable-under-cap text; media kinds → file exists.

- [x] **Step 1: Write the failing tests**

Append to `Tests/DreamuxTests/FileEditorTabSessionTests.swift` (inside the class):

```swift
    func testDefaultViewModes() {
        XCTAssertEqual(FileEditorTabSession.defaultViewMode(for: .markdown), .rendered)
        XCTAssertEqual(FileEditorTabSession.defaultViewMode(for: .tabular), .table)
        XCTAssertEqual(FileEditorTabSession.defaultViewMode(for: .code), .source)
        XCTAssertEqual(FileEditorTabSession.defaultViewMode(for: .image), .source)
    }

    @MainActor
    func testKindAndCurrentTextAssignedAtInit() throws {
        let url = sandbox.root.appendingPathComponent("notes.md")
        try "# hi\n".write(to: url, atomically: true, encoding: .utf8)
        let session = FileEditorTabSession(fileURL: url)
        XCTAssertEqual(session.kind, .markdown)
        XCTAssertEqual(session.viewMode, .rendered)
        XCTAssertEqual(session.currentText, "# hi\n")
        XCTAssertTrue(session.isSupported)
    }

    @MainActor
    func testMediaKindsSkipTextReadAndUseExistence() throws {
        // 3 MB of noise with a movie extension: over the text cap, but
        // media kinds never read text — existence is enough.
        let url = sandbox.root.appendingPathComponent("clip.mov")
        try Data(count: 3 * 1024 * 1024).write(to: url)
        let session = FileEditorTabSession(fileURL: url)
        XCTAssertEqual(session.kind, .video)
        XCTAssertTrue(session.isSupported)
        XCTAssertEqual(session.currentText, "")

        let missing = FileEditorTabSession(
            fileURL: sandbox.root.appendingPathComponent("gone.mov"))
        XCTAssertFalse(missing.isSupported)
    }

    @MainActor
    func testOversizedTextStillUnsupported() throws {
        let url = sandbox.root.appendingPathComponent("big.csv")
        try Data(count: 3 * 1024 * 1024).write(to: url)
        XCTAssertFalse(FileEditorTabSession(fileURL: url).isSupported)
    }
```

- [x] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FileEditorTabSessionTests 2>&1 | tail -5`
Expected: FAIL — `type 'FileEditorTabSession' has no member 'defaultViewMode'` (and friends).

- [x] **Step 3: Implement on the session**

In `Sources/Dreamux/Models/FileEditorTabSession.swift`:

Add above the class:

```swift
/// Which face a multi-mode file tab is showing. `.rendered` and
/// `.table` are the read views (MarkdownUI / NSTableView); `.source`
/// is the Monaco editor and is the only mode that can produce edits.
enum FileTabViewMode: String, Sendable {
    case rendered, source, table
}
```

Inside the class, replace the `contents` property and `init` and add the new API:

```swift
    let kind: FileTabKind
    var viewMode: FileTabViewMode
    /// The file's text as this session last knew it: disk contents at
    /// init, updated on every save and by `refreshCurrentTextFromEditor`.
    /// Read views (markdown preview, CSV table) render from this; empty
    /// for media kinds, which never read the file into memory.
    private(set) var currentText: String
    /// Placeholder escape hatch: render an unsupported file with Quick
    /// Look instead. Sticky per session so the choice survives redraws.
    var useQuickLookFallback = false

    init(fileURL: URL) {
        let resolved = fileURL.resolvingSymlinksInPath()
        self.fileURL = resolved
        self.title = resolved.lastPathComponent
        let kind = FileTabKind.kind(forPathExtension: resolved.pathExtension)
        self.kind = kind
        self.viewMode = Self.defaultViewMode(for: kind)
        if kind.isMonacoBacked {
            let loaded = Self.readText(at: resolved)
            self.currentText = loaded ?? ""
            self.isSupported = loaded != nil
        } else {
            self.currentText = ""
            self.isSupported = FileManager.default.fileExists(atPath: resolved.path)
        }
    }

    nonisolated static func defaultViewMode(for kind: FileTabKind) -> FileTabViewMode {
        switch kind {
        case .markdown: return .rendered
        case .tabular: return .table
        default: return .source
        }
    }

    /// Pull the live Monaco buffer into `currentText` so a rendered
    /// view reflects unsaved edits. No-op when the editor was never
    /// opened (nothing can have changed).
    func refreshCurrentTextFromEditor() {
        guard let _webView else { return }
        _webView.evaluateJavaScript("window.__getValue()") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, let text = result as? String else { return }
                self.currentText = text
            }
        }
    }
```

Also change `isSupported` from `let` to `private(set) var`? No — keep `let isSupported: Bool` exactly as declared today; both init branches above assign it once, which satisfies `let`. Update `handleReady()` and `handleSave` to use `currentText`:

```swift
    private func handleReady() {
        let js = "window.__setContents("
            + "\(Self.jsString(currentText)), "
            + "\(Self.jsString(fileURL.pathExtension)), "
            + "\(Self.jsString(Self.currentTheme())));"
        _webView?.evaluateJavaScript(js)
    }

    private func handleSave(text: String) {
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            currentText = text
            isDirty = false
        } catch {
            NSSound.beep()
        }
    }
```

Delete the old `private let contents: String` declaration (its doc comment too). Note `evaluateJavaScript`'s completion arrives on the main thread; `MainActor.assumeIsolated` is the codebase's established bridge (see `WorkspaceSession`'s Bonsplit delegate).

In `Sources/Dreamux/Models/WorkspaceSession.swift`, in `openFileTab(at:)`, replace the `createTab` line so the chip icon matches the kind:

```swift
        nextTabFileURL = resolved
        let kind = FileTabKind.kind(forPathExtension: resolved.pathExtension)
        controller.createTab(title: resolved.lastPathComponent, icon: kind.tabIcon)
        nextTabFileURL = nil
```

- [x] **Step 4: Run the full suite**

Run: `swift test 2>&1 | tail -3`
Expected: PASS — including the pre-existing `testSupportedFlagReflectsReadability` (unchanged semantics for `.swift`/`.bin`) and `WorkspaceSessionFileTabTests`.

- [x] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/FileEditorTabSession.swift Sources/Dreamux/Models/WorkspaceSession.swift Tests/DreamuxTests/FileEditorTabSessionTests.swift
git commit -m "Session-level file kind, view mode, and live text plumbing"
```

---

### Task 6: Markdown rendering (MarkdownUI) with Rendered|Raw toggle

**Files:**
- Modify: `Package.swift`
- Create: `Sources/Dreamux/Views/Viewers/MarkdownPreviewView.swift`
- Modify: `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift`

**Interfaces:**
- Consumes: Task 5's `viewMode`, `currentText`, `refreshCurrentTextFromEditor()`; the existing `FileEditorWebView`.
- Produces: `MarkdownPreviewView(text:)` (also consumed later by the plans work); `ViewerModeToggle` — a reusable segmented toggle used by Task 8's table view.

- [x] **Step 1: Add the dependency**

In `Package.swift` `dependencies:` array, after the bonsplit entry, add:

```swift
        // Markdown rendering for file tabs and (later) plan/spec docs.
        // GitHub-flavored: tables, fenced code, task-list checkboxes.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
```

In the `Dreamux` target's `dependencies:`, after the Bonsplit product line, add:

```swift
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
```

Run: `swift build 2>&1 | tail -3`
Expected: resolves and builds. (First resolve rewrites `Package.resolved` — commit it with this task.)

- [x] **Step 2: Create the preview view**

Create `Sources/Dreamux/Views/Viewers/MarkdownPreviewView.swift`:

```swift
import SwiftUI
import MarkdownUI

/// Read-only GitHub-flavored markdown: tables, fenced code blocks, and
/// task-list checkboxes (the superpowers plan format). Rendering theme
/// follows the system appearance via MarkdownUI's semantic colors.
struct MarkdownPreviewView: View {
    let text: String

    var body: some View {
        ScrollView {
            Markdown(text)
                .markdownTheme(.gitHub)
                .textSelection(.enabled)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
```

- [x] **Step 3: Add the toggle + markdown container in the tab content**

In `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift`, add below `FileEditorWebView`:

```swift
/// Segmented mode switch shown in a slim bar above multi-mode viewers
/// (markdown Rendered|Raw, tabular Table|Text).
struct ViewerModeToggle: View {
    @Bindable var session: FileEditorTabSession
    /// (label, mode) pairs, in display order.
    let options: [(String, FileTabViewMode)]

    var body: some View {
        HStack {
            Picker("", selection: $session.viewMode) {
                ForEach(options, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if session.isDirty {
                Text("Unsaved changes — ⌘S in Raw to save")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
        .onChange(of: session.viewMode) { _, newMode in
            // Entering a read view: sync the live Monaco buffer so the
            // render reflects unsaved edits (spec: re-render from the
            // current buffer, not disk).
            if newMode != .source { session.refreshCurrentTextFromEditor() }
        }
    }
}

/// A markdown tab: rendered preview by default, Monaco behind a toggle.
/// The webview (and its model/undo stack) is retained by the session,
/// so flipping modes never loses editor state.
private struct MarkdownTabView: View {
    @Bindable var session: FileEditorTabSession

    var body: some View {
        VStack(spacing: 0) {
            ViewerModeToggle(session: session,
                             options: [("Rendered", .rendered), ("Raw", .source)])
            Divider()
            if session.viewMode == .rendered {
                MarkdownPreviewView(text: session.currentText)
            } else {
                FileEditorWebView(webView: session.webView)
            }
        }
    }
}
```

Then in `FileEditorView`'s `body`, route markdown tabs to it (the full dispatcher lands in Task 9; for now, minimal):

```swift
    var body: some View {
        if session.kind == .markdown && session.isSupported {
            MarkdownTabView(session: session)
        } else if session.isSupported {
            FileEditorWebView(webView: session.webView)
        } else {
            // …existing placeholder VStack unchanged…
        }
    }
```

- [x] **Step 4: Build, test, and verify by hand**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: both pass.

Launch the app, open a `.md` file from the file tree: it renders (headings, checkboxes, code blocks); toggle Raw → Monaco with markdown highlighting; edit without saving, toggle Rendered → the edit is reflected; ⌘S in Raw saves.

- [x] **Step 5: Commit**

```bash
git add Package.swift Package.resolved Sources/Dreamux/Views/Viewers/MarkdownPreviewView.swift Sources/Dreamux/Views/WorkspaceTerminalContainer.swift
git commit -m "Render markdown tabs with MarkdownUI behind a Rendered|Raw toggle"
```

---

### Task 7: Native media viewers (image zoom, AV, PDF, Quick Look)

**Files:**
- Create: `Sources/Dreamux/Views/Viewers/ImageViewerView.swift`
- Create: `Sources/Dreamux/Views/Viewers/MediaPlayerView.swift`
- Create: `Sources/Dreamux/Views/Viewers/PDFViewerView.swift`
- Create: `Sources/Dreamux/Views/Viewers/QuickLookPreviewView.swift`

**Interfaces:**
- Consumes: only Foundation/AppKit/AVKit/PDFKit/Quartz and a `fileURL: URL`.
- Produces: `ImageViewerView(fileURL:)`, `MediaPlayerView(fileURL:)`, `PDFViewerView(fileURL:)`, `QuickLookPreviewView(fileURL:)` — all plain SwiftUI views, wired by Task 9.

- [x] **Step 1: Image viewer**

Create `Sources/Dreamux/Views/Viewers/ImageViewerView.swift`:

```swift
import SwiftUI
import AppKit

/// Zoomable image viewer: NSScrollView magnification (pinch + smart
/// zoom) around an NSImageView, with Fit / 100% controls and a live
/// zoom readout. Double-click toggles fit ↔ actual size.
struct ImageViewerView: View {
    let fileURL: URL
    @State private var zoomPercent: Int = 100
    @State private var command: ZoomCommand? = nil

    enum ZoomCommand: Equatable { case fit, actualSize }

    var body: some View {
        if let image = NSImage(contentsOf: fileURL) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button("Fit") { command = .fit }
                    Button("100%") { command = .actualSize }
                    Text("\(zoomPercent)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(image.size.width))×\(Int(image.size.height))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.bar)
                Divider()
                ZoomableImage(image: image, zoomPercent: $zoomPercent, command: $command)
            }
        } else {
            ContentUnavailableView(
                "Can't display \(fileURL.lastPathComponent)",
                systemImage: "photo.badge.exclamationmark",
                description: Text("The image failed to load.")
            )
        }
    }
}

private struct ZoomableImage: NSViewRepresentable {
    let image: NSImage
    @Binding var zoomPercent: Int
    @Binding var command: ImageViewerView.ZoomCommand?

    func makeNSView(context: Context) -> NSScrollView {
        let imageView = NSImageView(image: image)
        imageView.frame = NSRect(origin: .zero, size: image.size)
        imageView.imageScaling = .scaleAxesIndependently

        let scroll = NSScrollView()
        scroll.documentView = imageView
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 20
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor

        let doubleClick = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.didDoubleClick))
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)

        context.coordinator.scrollView = scroll
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.magnificationChanged),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scroll)

        DispatchQueue.main.async { context.coordinator.fit() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let command else { return }
        DispatchQueue.main.async {
            switch command {
            case .fit: context.coordinator.fit()
            case .actualSize: context.coordinator.setMagnification(1.0)
            }
            self.command = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomPercent: $zoomPercent, imageSize: image.size)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        private let zoomPercent: Binding<Int>
        private let imageSize: NSSize
        private var isFit = true

        init(zoomPercent: Binding<Int>, imageSize: NSSize) {
            self.zoomPercent = zoomPercent
            self.imageSize = imageSize
        }

        func fit() {
            guard let scroll = scrollView, let doc = scroll.documentView else { return }
            scroll.magnify(toFit: doc.frame)
            isFit = true
            publish()
        }

        func setMagnification(_ value: CGFloat) {
            guard let scroll = scrollView else { return }
            let center = NSPoint(x: imageSize.width / 2, y: imageSize.height / 2)
            scroll.setMagnification(value, centeredAt: center)
            isFit = false
            publish()
        }

        @objc func didDoubleClick() {
            isFit ? setMagnification(1.0) : fit()
        }

        @objc func magnificationChanged() {
            isFit = false
            publish()
        }

        private func publish() {
            guard let scroll = scrollView else { return }
            zoomPercent.wrappedValue = Int((scroll.magnification * 100).rounded())
        }
    }
}
```

- [x] **Step 2: AV player, PDF, and Quick Look wrappers**

Create `Sources/Dreamux/Views/Viewers/MediaPlayerView.swift`:

```swift
import SwiftUI
import AVKit

/// Video/audio playback with native transport controls. AVPlayer
/// streams from disk, so there is no size cap. The player pauses on
/// teardown (tab close); switching workspaces keeps tabs alive by
/// design (`keepAllAlive`), matching web-tab behavior.
struct MediaPlayerView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: fileURL)
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
```

Create `Sources/Dreamux/Views/Viewers/PDFViewerView.swift`:

```swift
import SwiftUI
import PDFKit

/// PDF rendering via PDFKit — page navigation, ⌘F find, and zoom come
/// with the view.
struct PDFViewerView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: fileURL)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}
```

Create `Sources/Dreamux/Views/Viewers/QuickLookPreviewView.swift`:

```swift
import SwiftUI
import Quartz

/// Read-only Quick Look preview — the system renderer for xlsx sheets,
/// docx pages, presentations, and anything else macOS can preview.
/// Falls back to an unavailable message when QL can't be constructed.
struct QuickLookPreviewView: View {
    let fileURL: URL

    var body: some View {
        if let preview = QLWrapper.make() {
            QLRepresentable(view: preview, fileURL: fileURL)
        } else {
            ContentUnavailableView(
                "No preview available",
                systemImage: "eye.slash",
                description: Text("Quick Look can't preview \(fileURL.lastPathComponent).")
            )
        }
    }
}

private enum QLWrapper {
    @MainActor static func make() -> QLPreviewView? {
        QLPreviewView(frame: .zero, style: .normal)
    }
}

private struct QLRepresentable: NSViewRepresentable {
    let view: QLPreviewView
    let fileURL: URL

    func makeNSView(context: Context) -> QLPreviewView {
        view.previewItem = fileURL as NSURL
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {}

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.close()
    }
}
```

- [x] **Step 3: Build**

Run: `swift build 2>&1 | tail -3`
Expected: builds clean (views are not yet reachable — Task 9 wires them; unreferenced types are fine).

- [x] **Step 4: Commit**

```bash
git add Sources/Dreamux/Views/Viewers/ImageViewerView.swift Sources/Dreamux/Views/Viewers/MediaPlayerView.swift Sources/Dreamux/Views/Viewers/PDFViewerView.swift Sources/Dreamux/Views/Viewers/QuickLookPreviewView.swift
git commit -m "Add native image/AV/PDF/QuickLook viewer views"
```

---

### Task 8: CSV table view with Table|Text toggle

**Files:**
- Create: `Sources/Dreamux/Views/Viewers/CSVTableView.swift`
- Modify: `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift`

**Interfaces:**
- Consumes: Task 4's `CSVTable`; Task 5's `currentText`/`viewMode`; Task 6's `ViewerModeToggle`.
- Produces: `TabularTabView(session:)` — wired by Task 9's dispatcher.

- [x] **Step 1: The table view**

Create `Sources/Dreamux/Views/Viewers/CSVTableView.swift`:

```swift
import SwiftUI
import AppKit

/// Virtualized, sortable, read-only table for CSV/TSV file tabs.
/// Sorting compares numerically when both cells parse as Double,
/// lexically otherwise. Header row handling is a toggle backed by the
/// `CSVTable.looksLikeHeader` heuristic.
struct CSVTableView: View {
    let text: String
    let delimiter: Character
    @State private var firstRowIsHeader: Bool? = nil   // nil = heuristic

    private static let displayLimit = 10_000

    var body: some View {
        let table = CSVTable.table(
            from: text,
            delimiter: delimiter,
            treatFirstRowAsHeader: firstRowIsHeader,
            displayLimit: Self.displayLimit
        )
        VStack(spacing: 0) {
            if let table {
                HStack {
                    Toggle("First row is header", isOn: Binding(
                        get: { firstRowIsHeader ?? (table.header != nil) },
                        set: { firstRowIsHeader = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    Spacer()
                    if table.isTruncated {
                        Label(
                            "Showing \(table.rows.count.formatted()) of \(table.totalDataRows.formatted()) rows",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    } else {
                        Text("\(table.totalDataRows.formatted()) rows")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.bar)
                Divider()
                CSVGrid(table: table)
            } else {
                ContentUnavailableView(
                    "Not tabular",
                    systemImage: "tablecells.badge.ellipsis",
                    description: Text("This file didn't parse as delimited data. Use the Text mode to view it.")
                )
            }
        }
    }
}

private struct CSVGrid: NSViewRepresentable {
    let table: CSVTable

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        context.coordinator.install(table: table, into: tableView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tableView = scroll.documentView as? NSTableView else { return }
        context.coordinator.install(table: table, into: tableView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var rows: [[String]] = []
        private var installedShape: (columns: Int, header: [String]?) = (0, nil)

        func install(table: CSVTable, into tableView: NSTableView) {
            rows = table.rows
            let columnCount = table.header?.count ?? table.rows.first?.count ?? 0
            let shape = (columnCount, table.header)
            if shape != installedShape {
                installedShape = shape
                for column in tableView.tableColumns { tableView.removeTableColumn(column) }
                for index in 0..<columnCount {
                    let id = NSUserInterfaceItemIdentifier("col\(index)")
                    let column = NSTableColumn(identifier: id)
                    column.title = table.header?[index] ?? "Column \(index + 1)"
                    column.sortDescriptorPrototype = NSSortDescriptor(
                        key: "\(index)", ascending: true)
                    column.width = 120
                    tableView.addTableColumn(column)
                }
            }
            tableView.reloadData()
        }

        nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
            MainActor.assumeIsolated { rows.count }
        }

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let tableColumn,
                  let index = Int(tableColumn.identifier.rawValue.dropFirst(3)),
                  rows.indices.contains(row),
                  rows[row].indices.contains(index) else { return nil }

            let id = NSUserInterfaceItemIdentifier("cell")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = id
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingTail
                field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = rows[row][index]
            return cell
        }

        func tableView(_ tableView: NSTableView,
                       sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key, let index = Int(key) else { return }
            let ascending = descriptor.ascending
            rows.sort { a, b in
                let lhs = index < a.count ? a[index] : ""
                let rhs = index < b.count ? b[index] : ""
                let result: Bool
                if let ln = Double(lhs), let rn = Double(rhs) {
                    result = ln < rn
                } else {
                    result = lhs.localizedStandardCompare(rhs) == .orderedAscending
                }
                return ascending ? result : !result
            }
            tableView.reloadData()
        }
    }
}
```

- [x] **Step 2: The tabular tab container**

In `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift`, next to `MarkdownTabView`, add:

```swift
/// A CSV/TSV tab: parsed table by default, Monaco text behind a toggle.
private struct TabularTabView: View {
    @Bindable var session: FileEditorTabSession

    private var delimiter: Character {
        session.fileURL.pathExtension.lowercased() == "tsv" ? "\t" : ","
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewerModeToggle(session: session,
                             options: [("Table", .table), ("Text", .source)])
            Divider()
            if session.viewMode == .table {
                CSVTableView(text: session.currentText, delimiter: delimiter)
            } else {
                FileEditorWebView(webView: session.webView)
            }
        }
    }
}
```

- [x] **Step 3: Build and verify by hand**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: both pass (TabularTabView is wired in Task 9; for a hand-check now, temporarily route `.tabular` in `FileEditorView` the same way Task 6 routed markdown — or defer the hand-check to Task 9).

- [x] **Step 4: Commit**

```bash
git add Sources/Dreamux/Views/Viewers/CSVTableView.swift Sources/Dreamux/Views/WorkspaceTerminalContainer.swift
git commit -m "Add sortable CSV/TSV table view with Table|Text toggle"
```

---

### Task 9: The dispatcher and the upgraded placeholder

**Files:**
- Modify: `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: final `FileEditorView` shape; `UnsupportedFileView` with size info, Reveal in Finder, and Try Quick Look.

- [x] **Step 1: Rewrite `FileEditorView` and the placeholder**

In `Sources/Dreamux/Views/WorkspaceTerminalContainer.swift`, replace the whole `FileEditorView` struct (keep `FileEditorWebView` as is) with:

```swift
/// Dispatch a file tab to its kind's viewer. Monaco-backed kinds can
/// still be unsupported (binary/oversized text); media kinds were
/// existence-checked at open.
private struct FileEditorView: View {
    @Bindable var session: FileEditorTabSession

    var body: some View {
        if !session.isSupported || session.useQuickLookFallback {
            if session.useQuickLookFallback {
                QuickLookPreviewView(fileURL: session.fileURL)
            } else {
                UnsupportedFileView(session: session)
            }
        } else {
            switch session.kind {
            case .markdown:
                MarkdownTabView(session: session)
            case .tabular:
                TabularTabView(session: session)
            case .image:
                ImageViewerView(fileURL: session.fileURL)
            case .video, .audio:
                MediaPlayerView(fileURL: session.fileURL)
            case .pdf:
                PDFViewerView(fileURL: session.fileURL)
            case .officePreview:
                QuickLookPreviewView(fileURL: session.fileURL)
            case .code:
                FileEditorWebView(webView: session.webView)
            }
        }
    }
}

/// Placeholder for text files that are binary or over the 2 MB cap,
/// with escape hatches: Quick Look often renders what Monaco can't.
private struct UnsupportedFileView: View {
    @Bindable var session: FileEditorTabSession

    private var fileSizeLabel: String? {
        guard let values = try? session.fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Can't display \(session.title)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(fileSizeLabel.map { "It's binary or too large to edit (\($0), 2 MB cap)." }
                 ?? "It's binary or larger than 2 MB.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                Button("Try Quick Look") { session.useQuickLookFallback = true }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([session.fileURL])
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

If Task 8's hand-check added a temporary `.tabular` route in the old `FileEditorView`, this rewrite subsumes it.

- [x] **Step 2: Build, test, and walk every kind by hand**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: both pass.

Launch the app and from a feature's file tree open one of each: `.swift` (Monaco, highlighted), `.toml` (Monaco, TOML colors), `.md` (rendered + toggle), `.csv` (table + sort + toggle), `.png` (zoom, Fit/100%, double-click), `.mp4` or `.mov` (plays), `.pdf` (pages), `.xlsx` (Quick Look cells), and a binary (placeholder → Try Quick Look → Reveal in Finder). Confirm tab chips show per-kind icons.

- [x] **Step 3: Commit**

```bash
git add Sources/Dreamux/Views/WorkspaceTerminalContainer.swift
git commit -m "Dispatch file tabs to per-kind viewers; richer unsupported placeholder"
```

---

### Task 10: E2E surface — kind and mode in the state dump

**Files:**
- Modify: `Sources/Dreamux/Models/WorkspaceSession.swift`
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift`
- Modify: `scripts/e2e/PROTOCOL.md`
- Test: `Tests/DreamuxTests/WorkspaceSessionFileTabTests.swift`

**Interfaces:**
- Consumes: Task 5's session fields.
- Produces: state dump `workspaces[].fileTabs` becomes `[{path, kind, mode, dirty}]` (was `[path]`). Nothing in `scripts/e2e/driver.py` consumes `fileTabs` yet — verified — so the shape change is safe.

- [x] **Step 1: Write the failing test**

Append to `Tests/DreamuxTests/WorkspaceSessionFileTabTests.swift` (match the existing test style in that file — it drives `openFileTab` against a real `WorkspaceSession`; reuse its setup helpers):

```swift
    @MainActor
    func testFileTabSummariesExposeKindAndMode() throws {
        let md = sandbox.root.appendingPathComponent("plan.md")
        try "# t\n".write(to: md, atomically: true, encoding: .utf8)
        session.openFileTab(at: md)

        let summaries = session.fileTabSummaries
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0]["path"], md.resolvingSymlinksInPath().path)
        XCTAssertEqual(summaries[0]["kind"], "markdown")
        XCTAssertEqual(summaries[0]["mode"], "rendered")
        XCTAssertEqual(summaries[0]["dirty"], "false")
    }
```

(If that test file's fixture names differ — e.g. the session variable is created per-test — adapt the body to its local conventions; the assertion set is what matters.)

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter WorkspaceSessionFileTabTests 2>&1 | tail -5`
Expected: FAIL — `value of type 'WorkspaceSession' has no member 'fileTabSummaries'`.

- [x] **Step 3: Implement**

In `Sources/Dreamux/Models/WorkspaceSession.swift`, replace the `openFileTabURLs` property with:

```swift
    /// Resolved paths of every open editor tab, for the e2e state dump.
    var openFileTabURLs: [URL] {
        fileTabSessions.values.map(\.fileURL)
    }

    /// Per-tab viewer facts for the e2e state dump: path, kind, active
    /// view mode, dirty flag. String-valued so it serializes as-is.
    var fileTabSummaries: [[String: String]] {
        fileTabSessions.values.map { session in
            [
                "path": session.fileURL.path,
                "kind": session.kind.rawValue,
                "mode": session.viewMode.rawValue,
                "dirty": session.isDirty ? "true" : "false",
            ]
        }
    }
```

In `Sources/Dreamux/E2E/E2ECommands.swift`, in the workspace mapping (currently `"fileTabs": store.session(for: workspace).openFileTabURLs.map(\.path)`), replace with:

```swift
                    "fileTabs": store.session(for: workspace).fileTabSummaries,
```

In `scripts/e2e/PROTOCOL.md`, find the `state` response documentation for `workspaces[].fileTabs` and update it to:

```markdown
- `fileTabs` — open editor tabs, one object per tab:
  `{"path": "<resolved absolute path>", "kind": "code|markdown|image|video|audio|pdf|officePreview|tabular", "mode": "rendered|source|table", "dirty": "true|false"}`.
  `kind` is decided from the file extension at open; `mode` is the
  active face of multi-mode viewers (markdown rendered/raw, tabular
  table/text).
```

- [x] **Step 4: Run the full suite**

Run: `swift test 2>&1 | tail -3`
Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/WorkspaceSession.swift Sources/Dreamux/E2E/E2ECommands.swift scripts/e2e/PROTOCOL.md Tests/DreamuxTests/WorkspaceSessionFileTabTests.swift
git commit -m "Expose file tab kind/mode/dirty in the e2e state dump"
```

---

## Final verification

- `swift build && swift test` — clean.
- Manual sweep from Task 9 Step 2 repeated once on a real project.
- `git log --oneline` shows one commit per task, no unrelated files staged.
