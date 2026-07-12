# Settings Split View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-house the Settings window as a System-Settings-style `NavigationSplitView` — sidebar of three categories (Appearance / Workflow / Connections), one grouped form per category.

**Architecture:** Pure view re-housing inside `SettingsView`: a `SettingsCategory` enum drives a sidebar `List(selection:)` with tinted icon badges; the detail pane switches between three `Form(.grouped)` bodies whose sections move verbatim from the current single form. No `@AppStorage` key, binding, control, or copy string changes.

**Tech Stack:** Swift 6 / SwiftUI (macOS 14 floor), SwiftPM.

**Spec:** `docs/superpowers/specs/2026-07-12-settings-split-view-design.md`

## Global Constraints

- macOS 14 floor; no new dependencies.
- Every existing section, control, footer/caption string, and `@AppStorage` binding moves **verbatim** — this plan adds structure only. `AppearanceSettings` / `WorkflowSettings` enums stay untouched at the top of the file.
- Sidebar rows: 22×22 `RoundedRectangle(cornerRadius: 5, style: .continuous)` badge filled with `tint.gradient`, white semibold 11pt SF Symbol, then the label. Appearance `paintbrush.fill` blue; Workflow `arrow.triangle.branch` green; Connections `key.fill` orange.
- Window frame fixed 720×440; sidebar column width 190.
- Commit style `Prefix: summary`; stage ONLY named files; never touch `.claude/worktrees/`.

---

### Task 1: SettingsView split view

**Files:**
- Modify: `Sources/Dreamux/Views/SettingsView.swift` (the `SettingsView` struct only, currently ~lines 55–159)

**Interfaces:**
- Consumes: existing `AppearanceSettings`/`WorkflowSettings` keys, `colorBinding(_:fallback:)`, `ConnectionsSettingsView(store: .shared)`.
- Produces: nothing downstream (Settings scene is a leaf).

- [ ] **Step 1: Add the category enum**

Inside `SettingsView.swift`, above `struct SettingsView` (file-private — nothing else needs it):

```swift
/// Sidebar categories of the Settings window — System Settings style:
/// tinted icon badge + label on the left, one grouped form per category
/// on the right.
private enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance, workflow, connections

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .workflow: "Workflow"
        case .connections: "Connections"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintbrush.fill"
        case .workflow: "arrow.triangle.branch"
        case .connections: "key.fill"
        }
    }

    var tint: Color {
        switch self {
        case .appearance: .blue
        case .workflow: .green
        case .connections: .orange
        }
    }
}
```

- [ ] **Step 2: Re-house the body**

In `SettingsView`, add the selection state next to the existing `@AppStorage` properties:

```swift
/// Optional so List deselection can't blank the pane — the detail
/// falls back to .appearance.
@State private var category: SettingsCategory? = .appearance
```

Replace the current `body` (the single `Form { ... } .formStyle(.grouped).frame(width: 470).fixedSize(...)`) with:

```swift
var body: some View {
    NavigationSplitView {
        List(SettingsCategory.allCases, selection: $category) { item in
            Label {
                Text(item.title)
            } icon: {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(item.tint.gradient)
                    .frame(width: 22, height: 22)
                    .overlay {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
            .tag(item)
        }
        .navigationSplitViewColumnWidth(190)
    } detail: {
        Form {
            switch category ?? .appearance {
            case .appearance: appearanceSections
            case .workflow: workflowSection
            case .connections: connectionsSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle((category ?? .appearance).title)
    }
    .frame(width: 720, height: 440)
}
```

Then move the existing sections — **verbatim, no edits to any control or string** — into three `@ViewBuilder` properties on `SettingsView`:

```swift
/// "Inset card" + "Colors & transparency" — moved unchanged from the
/// old single-form body.
@ViewBuilder private var appearanceSections: some View {
    Section("Inset card") {
        // …the existing Toggle / Picker / LabeledContent block, verbatim…
    }
    Section {
        // …the existing transparency/color block, verbatim…
    } header: {
        Text("Colors & transparency")
    } footer: {
        // …the existing footer Text, verbatim…
    }
}

@ViewBuilder private var workflowSection: some View {
    Section {
        // …the existing auto-commit Toggle + caption, verbatim…
    } header: {
        Text("Workflow")
    }
}

@ViewBuilder private var connectionsSection: some View {
    Section("Connections") {
        ConnectionsSettingsView(store: .shared)
    }
}
```

(The `// …verbatim…` markers above stand for the exact blocks currently in the body — cut and paste them without modification; they are not placeholders for new code.)

- [ ] **Step 3: Build + regression**

Run: `swift build 2>&1 | tail -3` → `Build complete!`
Run: `swift test 2>&1 | tail -3` → 0 failures.

- [ ] **Step 4: Commit**

```bash
git add Sources/Dreamux/Views/SettingsView.swift
git commit -m "Settings: System-Settings-style split view (Appearance/Workflow/Connections)"
```

---

## Verification (after the task)

- Manual (relaunched app): ⌘, opens at 720×440 with Appearance selected and titled "Appearance"; all appearance knobs live-update the window; Workflow toggle persists; Connections pane lists/adds/deletes; switching categories never blanks the pane.
