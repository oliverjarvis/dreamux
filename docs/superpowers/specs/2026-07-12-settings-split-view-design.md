# Settings Window: Sidebar + Content — Design

**Date:** 2026-07-12
**Status:** Approved (brainstorm complete)

## Problem

The Settings window (⌘,) is a single 470pt grouped `Form` with four
stacked sections. The user wants the classic macOS System Settings shape:
a sidebar of categories on the left, one category's content on the right.

## Decisions

- **Shape: `NavigationSplitView`** (approved over pre-Ventura toolbar
  tabs) inside the existing `Settings` scene.
- **Three categories** from the existing sections:
  - **Appearance** — "Inset card" + "Colors & transparency" sections.
  - **Workflow** — the auto-commit section.
  - **Connections** — `ConnectionsSettingsView`.
- This is a re-housing, not a settings rework: every `@AppStorage` key,
  binding, control, and copy string moves verbatim. `AppearanceSettings`
  / `WorkflowSettings` enums stay where they are.

## Layout

- Sidebar (~190pt column width): `List(selection:)` of the categories —
  System Settings style rows: a 22×22 `RoundedRectangle(cornerRadius: 5)`
  badge filled with the category tint (`.gradient`), white semibold 11pt
  SF Symbol inside, then the 13pt label. Tints/symbols: Appearance
  `paintbrush.fill` blue; Workflow `arrow.triangle.branch` green;
  Connections `key.fill` orange.
- Detail: one `Form(.grouped)` per category (sections moved verbatim);
  `.navigationTitle(category.title)` so the window titles itself after
  the selection.
- Selection: `@State` `SettingsCategory?` defaulting to `.appearance`;
  detail renders `category ?? .appearance` so deselection can't blank
  the pane.
- Window frame: fixed 720×440.

## Testing

- Build + full unit suite (no logic change — pure view re-housing; the
  `WorkflowSettings.autoCommitEnabled` fallback and hex helpers keep
  their existing coverage).
- Manual: ⌘, opens with Appearance selected; all controls function in
  each pane; Connections list renders.

## Out of scope

- New settings, search, or per-category icons in the toolbar.
- Persisting the selected category across opens.
