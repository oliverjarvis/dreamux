# Dreamux

A native macOS app (SwiftUI, SwiftPM) for orchestrating Claude-driven work
across git worktrees — plans/specs, runs, flows, and repositories in one
project window.

## UI & design

What makes this app's chrome read well — learned the hard way while
reworking the sidebar. Apply these when touching any view.

### Be generous with size and space, not dense

The instinct to make a sidebar "tight/compact like Slack" is wrong — Slack
actually feels **generous**: comfortable fonts, roomy rows, readable
hierarchy. Cramming things smaller makes them hard to read and cheap-looking.
Concrete scale that reads well here:

- **Row labels / file names:** 14–15pt. Never `.caption2` (11pt) for a real,
  clickable row.
- **Section headers** (CONTEXT, FLOWS, REPOSITORIES): 13pt semibold, light
  uppercase kerning (~0.4).
- **Nested sub-group headers** (Plans, Specs under Context): 14pt medium,
  **primary** color — a sub-level is still a first-class row, not a faint
  whisper. Do not shrink sub-items to signal nesting.
- **Icons:** 14–16pt; give leading glyphs a fixed-width frame so columns
  line up.
- **Counts / metadata:** ~12–13pt, `.secondary` — not tiny `.tertiary`.
- **Row vertical padding:** 6–8pt. **Section spacing:** ~18pt.

### Show hierarchy with alignment and indentation, not by shrinking

Siblings render at the same size and their glyph columns line up. A file that
sits at a group's level (e.g. CLAUDE.md alongside the Plans/Specs groups)
aligns its icon with those groups' chevrons; a file *nested inside* a group
indents past it. Reach for a shared row builder with a `leadingInset`/
`iconWidth` parameter rather than duplicating rows at different sizes.

### Prefer few top-level sections

Don't sprout a top-level header per data kind. Related lists collapse under
one section (e.g. Plans + Specs + config files all live under **Context**).
Fewer, well-named sections beat a wall of tiny headers.

### Consistent control shapes

Header controls (run/play, commit) share one shape: an **outlined pill**
(`RoundedRectangle` cornerRadius 8, `strokeBorder` `.secondary.opacity(0.3)`,
subtle `.primary.opacity(0.04)` fill) split into segments by a 1pt hairline
divider, with a `chevron.down` segment when it opens a popover. Match this
shape for any new header control so they read as a set.

### Don't let a component library paint its own page background

MarkdownUI's `.gitHub` theme sets `BackgroundColor(.background)` on its base
text style, painting a solid `#18191d` behind every run — it hugs the content
and reads as a mismatched card floating on our darker pane. Clear a
library theme's page/text background and let content sit on the app's own
surface; keep only the backgrounds that are meaningful (code blocks,
blockquotes). Fill preview panes edge-to-edge (`maxWidth`/`maxHeight
.infinity`) so a document surface never becomes a content-sized card.

### Graph/DAG layout

The Flows graph is laid out by **SwiftDagre** (a pure-Swift dagre port)
behind `FlowLayoutEngine`'s interface — layered ranks, crossing reduction,
and routed edge waypoints. Draw edges as smoothed splines through those
waypoints with arrowheads into the target border; don't fall back to
straight center-to-center lines. Self-loops are excluded from dagre and
drawn as a self-arc by the view.

### Name the shared concept instead of splitting a section

The work-items rail felt "cursed" because the `main` worktree (a pure
place, no plan) sat among plan-run cards under a header called **FLOWS** —
as if `main` were a run. The fix was *not* to pull `main` into its own
`MAIN` section: that just traded one seam for two headers, a redundant
label ("MAIN" over a `main` row), and an orphaned divider — each of which
felt off in turn. The fix was to **rename the section to the concept that
spans both**: `main` and every run are *workspaces* (worktrees you can
open), so one **Workspaces** section holds `main` as its first row and the
runs beneath it. When a list feels like it's mixing kinds, first ask
whether one honest name encompasses them — reframing beats partitioning.

### One hover wash for every row; no rules under headers

Every clickable row uses the same wash: `Color.primary.opacity(0.04)` on
hover, `0.08` when selected, on a `RoundedRectangle(cornerRadius: 8)`. The
base `main` row is **not** exempt — a row that doesn't light up on hover
like its neighbours reads as dead. Sections are delineated by their
uppercase header (13pt semibold, kern ~0.4) and generous spacing **alone**
— never a `Divider()` under a header. A rule beneath one section's title
makes it read as a different *kind* of element than its peers.

### Add-actions are labelled rows at the foot of the list, not header icons

"New workspace" / "Add repository" live as a **borderless row at the bottom
of their list** — a plain `plus` (no circle, no box), 15pt label, hover-only
background — not a `+` icon crammed into the section header. And drop
controls a watcher makes redundant: with `docStore.startWatching()`
auto-rescanning on file changes, there is no manual "refresh" button.

### Master–detail: the rail launches, the Overview tab holds the detail

A ~260px rail can't render a plan → phases → tasks tree without truncating.
Detail lives on each workspace's always-present, non-closable **Overview
tab** (Mode A for a plan-backed run, Mode B for `main`/scratch); the rail
stays a compact launcher/monitor — status glyph, title, progress bar, and a
single "current: Phase · Task" line. Clicking a run activates its workspace
and focuses that Overview; per-task "View changes" and "Course correct"
live on the Overview's checklist, not the rail.
