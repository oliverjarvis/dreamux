# Features Section Retirement — Implementation Plan

**Spec:** docs/superpowers/specs/2026-07-03-initiative-sidebar-design.md (section "Features section retirement"). Prerequisite: `2026-07-03-initiative-sidebar.md` fully merged — plan rows must already exist.

**Goal:** Remove the Features list from `WorkspaceSidebar`. Plan-backed workspaces become reachable only through their plan rows (full action parity); plan-less work items move to a compact **Ad hoc** group, hidden when empty.

## Global Constraints

- Same as the initiative-sidebar plan (strict concurrency, native controls, no new deps, PROTOCOL.md lockstep, tests stay green).
- The merge/close sheets and their confirmation flows stay owned by `WorkspaceSidebar`; the section reaches them through pending-channel bindings exactly like `gateMergeWorkspaceID` does today.
- No `WorkspaceStore` model changes — this is presentation-only; worktree provisioning, discovery, and cleanup flows are untouched.

### Task 1: Run-control parity on plan rows

- [ ] **Step 1:** `PlansSpecsSection` gains the run-control affordances for rows whose feature workspace exists: play/stop (start/stop runners on that branch), the open-services safari menu, and *Run Settings…* — reuse `WorkspaceSidebar.runControls`' logic by extracting it into a shared component (`Views/WorkspaceRunControls.swift`) parameterized by workspace + `RunnerManager`, used by both feature rows (until Task 4 deletes them) and plan rows.
- [ ] **Step 2:** Wire the needed inputs through the section's init (runners reference or closures — follow the existing dependency style; prefer passing `RunnerManager` since the sidebar already holds it).
- [ ] **Step 3: Build + tests green; hover a running plan row shows stop + safari controls.**

### Task 2: Merge/Close parity on plan rows

- [ ] **Step 1:** Plan-row context menu gains *Merge…* (workspaces with linked repos) and *Close "<feature>"…* (destructive), routed through two new pending channels on `ProjectSession` (`pendingGateMergeWorkspaceID` already exists and is reused for merge; add `pendingCloseWorkspaceID`) consumed by `WorkspaceSidebar`'s existing sheet/alert owners.
- [ ] **Step 2:** Unit-test the channel handoff at the `ProjectSession` level (set channel → sidebar consumption is UI, but the channel semantics — set/clear once — get a test like `testRequestMergeParksWorkspaceOnGateChannel`).
- [ ] **Step 3: Build + tests green.**

### Task 3: Ad hoc group

- [ ] **Step 1:** In `WorkspaceSidebar`, compute plan-backed feature names from `docStore.initiatives` (ledger featureName ?? branch-name derivation per plan). Workspaces NOT in that set are ad hoc.
- [ ] **Step 2:** Render them under a small `Ad hoc` section label (same `sectionLabel` chrome as Features today), keeping today's row body: badge, name line + unread dot, repo subtitle, run controls, context menu (including *Customize…*, which stays exclusive to ad-hoc rows — tile symbol/tint has no meaning on plan rows). Reorder within the group keeps the existing `ReorderDropDelegate` wiring. Hidden entirely when no ad-hoc workspaces exist.
- [ ] **Step 3: Build + tests green.**

### Task 4: Remove the Features section

- [ ] **Step 1:** Delete the Features list rendering (`sectionLabel("Features")`, feature `ForEach`, `emptyFeaturesText` path) — plan-backed workspaces now render nowhere except their plan rows; keep Add Feature/`hasNoFeaturesOrRepos` affordances by moving the add-feature entry point onto the Ad hoc section header (`+`) so ad-hoc creation survives.
- [ ] **Step 2:** Sweep copy that references the Features section: `WorkspaceTerminalContainer.noWorkspacesState` ("Add a feature from the sidebar…"), onboarding/empty states, and any `.help` strings.
- [ ] **Step 3:** e2e: `state`'s `workspaces` dump is store-level and stays; note the UI change in PROTOCOL.md's `createFeature`/targeting prose if it references the Features list; adjust any e2e scenario scripts that clicked/screenshotted the Features section.
- [ ] **Step 4: Build + tests green.**

### Task 5: Parity sweep + whole-branch verification

- [ ] **Step 1:** Parity checklist, each demonstrated via e2e/GUI on a plan-backed workspace from its plan row: activate (→ workspace pane), unread dot, start/stop runners, open services, Run Settings scoping, Merge… (sheet opens), Close (confirm + worktree removal), gate-card Merge & Continue still works end-to-end with the queue.
- [ ] **Step 2:** Ad hoc checks: plan-less workspace appears in Ad hoc with full controls; group hidden when empty; Add Feature still creates one.
- [ ] **Step 3:** Full `swift build` + `swift test`; screenshots of the final sidebar (no Features section; Ad hoc present/absent).
- [ ] **Step 4:** Update the spec's rollout note once merged.
