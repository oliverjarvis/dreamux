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
