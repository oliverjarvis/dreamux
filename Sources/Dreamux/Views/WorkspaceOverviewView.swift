import SwiftUI

/// Bundles the Overview's plan-backed (Mode A) dependencies so
/// `WorkspaceTerminalContainer` → `WorkspaceBonsplitPane` → `TabContentView`
/// can thread them to whichever workspace's tab needs them in one shot,
/// instead of repeating this parameter list at each hop (mirrors
/// `FlowGateActions` bundling the gate closures for the same reason).
struct WorkspaceOverviewDependencies {
    let docStore: DocStore
    let planQueue: PlanQueueController
    let repoStore: RepoStore
    let featureName: (PlanDoc) -> String?
    /// Whether a feature name currently has a live workspace — the same
    /// closure `PlansSpecsSection.featureExists` is, needed so main's
    /// mini-dashboard (Group 3) can derive each plan's real status
    /// rather than assuming the feature exists (Mode A can assume it
    /// for the workspace it's rendering; the summary list can't).
    let featureExists: (String) -> Bool
    let onOpenDoc: (URL) -> Void
    let onOpenDocAtLine: (URL, Int) -> Void
    let makeRunControls: (Workspace) -> HeaderRunControls
    /// Run *the plan* (start/resume the claude agent) — the lime pill,
    /// distinct from `makeRunControls`' run.toml services. Presents the same
    /// RunPlanSheet the rail's Run pill does, lifted to the window.
    let onRunPlan: (PlanDoc) -> Void
    /// Whether a claude agent is actually live (busy/waiting) on this
    /// workspace — the same busy/waiting-lane signal the rail card uses to
    /// decide whether "Run the plan" applies (a `.running` *status* alone
    /// only means the plan was started).
    let hasLiveAgent: (Workspace) -> Bool
    let gateActions: FlowGateActions
    /// Mode B's "Plan something here" — the same New Plan sheet the rail's
    /// `+` opens (`WorkspaceSidebar`'s `showNewPlan`), triggered a second
    /// way from a plain workspace's Overview.
    let onNewPlan: () -> Void
    /// Main's mini-dashboard row action: jump to a run's workspace and
    /// focus its Overview, or (no workspace yet) open the plan doc —
    /// same fallback the rail's not-yet-run click uses. Owns the
    /// `store.featureWorkspace`/`store.activate`/`focusOverview` wiring
    /// so this view stays store-free like its sibling closures.
    let onOpenRun: (PlanDoc) -> Void
    /// Resolve a task's recorded commits into a diff tab (or explain why
    /// there's nothing to show) — the checklist's per-task hover button
    /// and context-menu item both call straight through to this. Mirrors
    /// `WorkspaceSidebar.viewTaskChanges` (this is the checklist's only
    /// remaining trigger for it now that the rail's own task row is gone).
    let onViewTaskChanges: (PlanDoc, PlanTask) -> Void
    /// Enqueue a course-correction nudge on the project's `PlanNudgeCenter`
    /// — forwarded straight into the checklist's own course-correct sheet,
    /// the same way `WorkspaceSidebar` forwards it into `PlansSpecsSection`.
    let onCourseCorrectionNudge: (PlanDoc, String, CorrectionPriority) -> Void
}

/// The workspace's home dashboard — its pinned, non-dismissable first
/// tab. Two modes, chosen by whether a plan backs this workspace:
///
/// - **Mode A** (this file, Group 2): a plan resolves for
///   `session.workspace.name` — a full-width, readable run dashboard:
///   header, spec/progress, the relocated task checklist (sized up from
///   the rail's cramped accordion), and the run/terminal/diff/gate
///   actions.
/// - **Mode B** (this file, Group 3): no plan resolves — a lighter
///   overview for a plain workspace (main, scratch): branch/working-tree
///   header and quick actions (shell, services, diff, plan something
///   here).
struct WorkspaceOverviewView: View {
    @Bindable var session: WorkspaceSession
    let docStore: DocStore
    let planQueue: PlanQueueController
    /// Mode B's working-tree header resolves this workspace's worktree
    /// through it (mirrors `ContentView.resolveGitStatus`'s repo lookup) —
    /// Mode A doesn't read it (the branch-vs-base diff goes through
    /// `gateActions` instead, which already resolves worktrees itself).
    let repoStore: RepoStore
    /// The same feature-name resolver the rail uses (ledger record first,
    /// else filename-derived branch) — matched against
    /// `session.workspace.name` via `WorkspacePlanResolver`.
    let featureName: (PlanDoc) -> String?
    /// Main's mini-dashboard status derivation — see
    /// `WorkspaceOverviewDependencies.featureExists`.
    let featureExists: (String) -> Bool
    let onOpenDoc: (URL) -> Void
    /// Open a doc jumped to a 1-based line — the checklist's phase/task
    /// rows open the plan at the clicked section.
    let onOpenDocAtLine: (URL, Int) -> Void
    /// Builds the shared run-control cluster for a workspace (start/stop
    /// services, open, Run Settings) — the same closure the rail's plan
    /// rows and feature rows use.
    let makeRunControls: (Workspace) -> HeaderRunControls
    /// See `WorkspaceOverviewDependencies.onRunPlan` — the lime "Run the
    /// plan" pill, distinct from the services control above.
    let onRunPlan: (PlanDoc) -> Void
    /// See `WorkspaceOverviewDependencies.hasLiveAgent`.
    let hasLiveAgent: (Workspace) -> Bool
    /// Gate review/merge wiring, shared verbatim with the Flows page's
    /// gate cards (`ContentView.flowGateActions`) so a merge here and a
    /// merge from Flows can't drift.
    let gateActions: FlowGateActions
    /// Mode B's "Plan something here".
    let onNewPlan: () -> Void
    /// Main's mini-dashboard row action — see
    /// `WorkspaceOverviewDependencies.onOpenRun`.
    let onOpenRun: (PlanDoc) -> Void
    /// See `WorkspaceOverviewDependencies.onViewTaskChanges`.
    let onViewTaskChanges: (PlanDoc, PlanTask) -> Void
    /// See `WorkspaceOverviewDependencies.onCourseCorrectionNudge`.
    let onCourseCorrectionNudge: (PlanDoc, String, CorrectionPriority) -> Void

    /// Mode B's working-tree summary — loaded once on appear (no poller;
    /// unlike the header chip's 5s loop, this tab isn't always on
    /// screen), keyed to the workspace so it reloads if this view instance
    /// ever gets reused for a different workspace.
    @State private var headStatus: GitHeadStatus?
    /// Task row currently under the pointer — drives the hover-revealed
    /// "View changes" button, keyed by the task's line (mirrors the
    /// rail's now-deleted `hoveredTaskLine`).
    @State private var hoveredTaskLine: Int?
    /// The row a *Course correct…* was fired from, driving the sheet —
    /// this view's own copy of `PlansSpecsSection.CorrectionTarget` (the
    /// checklist's task/phase rows are its only remaining trigger for
    /// those two anchors; the plan-level `.currentPhase` entry stays on
    /// the rail's context menu).
    @State private var correcting: CorrectionTarget?

    /// See `PlansSpecsSection.CorrectionTarget` — the same shape, kept as
    /// this view's own private copy rather than a shared type so the two
    /// views' course-correct wiring stays independently editable.
    private struct CorrectionTarget: Identifiable {
        let id = UUID()
        let plan: PlanDoc
        let anchor: CourseCorrection.Anchor
        let description: String
    }

    private var resolvedPlan: PlanDoc? {
        WorkspacePlanResolver.plan(
            forWorkspaceNamed: session.workspace.name,
            plans: docStore.plans,
            featureName: featureName)
    }

    var body: some View {
        Group {
            if let plan = resolvedPlan {
                modeA(plan)
            } else {
                modeB()
            }
        }
        .sheet(item: $correcting) { target in
            CourseCorrectSheet(
                anchorDescription: target.description,
                onSubmit: { text, priority in
                    submitCorrection(target, text: text, priority: priority)
                },
                onCancel: { correcting = nil }
            )
        }
    }

    /// Write the fix-task at the target's anchor, then — only for a plan
    /// with a live agent — enqueue the priority-worded nudge. Mirrors
    /// `PlansSpecsSection.submitCorrection`; this view needs its own copy
    /// since the checklist's task/phase rows are its only remaining
    /// trigger for these two anchors.
    private func submitCorrection(
        _ target: CorrectionTarget, text: String, priority: CorrectionPriority
    ) {
        correcting = nil
        let summary = CourseCorrection.summaryLine(from: text)
        let date = CourseCorrection.markerDate()
        try? CourseCorrection.apply(
            to: target.plan.fileURL, anchor: target.anchor,
            summary: summary, body: text, date: date)
        // Nudge only a running plan (its agent is live to receive it);
        // idle plans just get the tracked fix-task the write above added.
        let status = docStore.status(for: target.plan, featureExists: featureExists)
        if status == .running || status == .awaitingReview {
            onCourseCorrectionNudge(target.plan, summary, priority)
        }
    }

    // MARK: - Mode A

    private func modeA(_ plan: PlanDoc) -> some View {
        // The workspace this Overview belongs to unarguably exists (we're
        // rendering its tab), so the plan behind it is never `.ready`/
        // `.specOnly` in practice — `featureExists` is trivially true here.
        let status = docStore.status(for: plan, featureExists: { _ in true })
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(plan, status: status)
                Divider()
                specAndProgress(plan)
                Divider()
                checklist(plan)
                Divider()
                actionsRow(plan)
                gateSection(plan)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header

    private func header(_ plan: PlanDoc, status: PlanStatus) -> some View {
        let startedAt = docStore.ledger.recordForPlan(docStore.relativePath(of: plan))?.startedAt
        let flow = flowStatus(for: status)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: FlowStatusGlyph.symbol(flow))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(FlowStatusGlyph.color(flow))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(status.label)
                    if let startedAt {
                        Text("·").foregroundStyle(.tertiary)
                        Text(startedAt, style: .relative)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .semibold))
                    Text(session.workspace.name)
                    if !session.workspace.linkedRepoIDs.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(session.workspace.linkedRepoIDs.joined(separator: " · "))
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }

    /// `PlanStatus` → `FlowStatus`, so the header can reuse
    /// `FlowStatusGlyph` (Global Constraint: shared status glyph/color
    /// vocabulary) instead of inventing its own tint rules.
    private func flowStatus(for status: PlanStatus) -> FlowStatus {
        switch status {
        case .running: return .running
        case .awaitingReview: return .waiting
        case .merged: return .done
        case .inProgress, .ready, .specOnly: return .queued
        }
    }

    // MARK: - Spec + progress

    private func specAndProgress(_ plan: PlanDoc) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let chips = docChips(for: plan)
            if !chips.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                        if index > 0 {
                            Text("·").foregroundStyle(.tertiary)
                        }
                        Button { onOpenDoc(chip.url) } label: {
                            Text(chip.label)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13, weight: .medium))
            }
            if plan.totalSteps > 0 {
                Text("\(plan.checkedSteps) / \(plan.totalSteps) steps")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(plan.checkedSteps), total: Double(plan.totalSteps))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// The plan's initiative doc chips (spec/roadmap) — same labeling as
    /// the rail's `docChips(for:)`, rebuilt here since that method is
    /// private to `PlansSpecsSection`.
    private func docChips(for plan: PlanDoc) -> [(label: String, url: URL)] {
        guard let initiative = docStore.initiatives.first(where: { $0.plans.contains(plan) })
        else { return [] }
        var chips: [(label: String, url: URL)] = []
        if let spec = initiative.spec {
            chips.append((DocChipLabel.label(title: spec.title, isSpec: true), spec.fileURL))
        }
        chips.append(contentsOf: initiative.supportingDocs.map {
            (DocChipLabel.label(title: $0.title, isSpec: false), $0.fileURL)
        })
        return chips
    }

    // MARK: - Checklist (lifted from PlansSpecsSection's rail accordion,
    // sized up — the relocated tree with room: no collapsing needed once
    // it isn't crammed into the sidebar).

    @ViewBuilder
    private func checklist(_ plan: PlanDoc) -> some View {
        let tasks = plan.tasks.filter { !$0.steps.isEmpty }
        if PlanPhases.shouldGroup(tasks) {
            let groups = PlanPhases.groups(tasks)
            let currentGroup = PlanPhases.currentGroupIndex(groups)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    phaseSection(group, plan: plan, isCurrentGroup: index == currentGroup)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                taskRows(tasks, plan: plan)
            }
        }
    }

    private func phaseSection(
        _ group: PlanPhases.Group, plan: PlanDoc, isCurrentGroup: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let line = group.tasks.first?.phaseLine ?? group.tasks.first?.line {
                    onOpenDocAtLine(plan.fileURL, line)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(group.phase ?? "Steps")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    if isCurrentGroup {
                        Text("← current")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("\(group.checkedSteps)/\(group.totalSteps)")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Course correct…") {
                    correcting = CorrectionTarget(
                        plan: plan,
                        anchor: .phase(name: group.phase ?? ""),
                        description: group.phase ?? "Steps")
                }
            }
            taskRows(group.tasks, plan: plan)
        }
    }

    private func taskRows(_ tasks: [PlanTask], plan: PlanDoc) -> some View {
        let currentIndex = tasks.firstIndex { $0.steps.contains { !$0.checked } }
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                taskRow(task, plan: plan, isCurrent: index == currentIndex)
            }
        }
    }

    private func taskRow(_ task: PlanTask, plan: PlanDoc, isCurrent: Bool) -> some View {
        let checked = task.steps.filter(\.checked).count
        let total = task.steps.count
        let allChecked = checked == total
        let glyph = allChecked ? "checkmark" : (isCurrent ? "arrowtriangle.right.fill" : "circle")
        let tint = isCurrent
            ? AnyShapeStyle(Color.accentColor)
            : AnyShapeStyle(allChecked ? .secondary : .tertiary)
        return Button {
            onOpenDocAtLine(plan.fileURL, task.line)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: glyph)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(task.title.isEmpty ? "Steps" : task.title)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.tail)
                if isCurrent {
                    Text("← current")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                // Hover button only when at least one step is checked — an
                // untouched task can't have commits yet. Rendered whenever
                // checked, faded by hover, so the count never shifts
                // (mirrors the rail's now-deleted task row).
                if checked > 0 {
                    let show = hoveredTaskLine == task.line
                    Button {
                        onViewTaskChanges(plan, task)
                    } label: {
                        Image(systemName: "plus.forwardslash.minus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("View this task's changes")
                    .opacity(show ? 1 : 0)
                    .allowsHitTesting(show)
                }
                Text("\(checked)/\(total)")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            }
        }
        .contextMenu {
            Button("View changes") {
                onViewTaskChanges(plan, task)
            }
            Button("Course correct…") {
                correcting = CorrectionTarget(
                    plan: plan,
                    anchor: .task(line: task.line),
                    description: task.title.isEmpty ? "this task" : task.title)
            }
        }
        .onHover { inside in
            if inside { hoveredTaskLine = task.line }
            else if hoveredTaskLine == task.line { hoveredTaskLine = nil }
        }
    }

    // MARK: - Actions

    private func actionsRow(_ plan: PlanDoc) -> some View {
        // Lime pill runs the *plan* (start/resume the agent); shown while the
        // plan is incomplete AND no agent is live on it (a `.running` status
        // alone just means it was started). `makeRunControls` is the
        // separate run.toml services control.
        let status = docStore.status(for: plan, featureExists: featureExists)
        let incomplete = status == .ready || status == .inProgress || status == .running
        let live = hasLiveAgent(session.workspace)
        let canRun = incomplete && !live
        return HStack(spacing: 12) {
            if canRun {
                RunPlanButton { onRunPlan(plan) }
            } else if incomplete && live {
                RunningIndicator()
            }
            makeRunControls(session.workspace)
            Button(action: openOrFocusTerminal) {
                Label("Open terminal", systemImage: "terminal")
            }
            .buttonStyle(.bordered)
            BranchChangesButton(workspaceID: session.workspace.id, actions: gateActions)
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
    }

    /// Reuse an already-open shell tab if this workspace has one; otherwise
    /// open a fresh one. No new session machinery — just the existing
    /// controller/tabSession lookups `WorkspaceSession` already exposes.
    private func openOrFocusTerminal() {
        if let pane = session.controller.focusedPaneId,
           let shellTab = session.controller.tabs(inPane: pane)
               .first(where: { session.tabSession(for: $0.id) != nil }) {
            session.controller.selectTab(shellTab.id)
            TerminalFocus.focusVisibleTerminal()
        } else {
            session.createTab()
        }
    }

    // MARK: - Gate

    @ViewBuilder
    private func gateSection(_ plan: PlanDoc) -> some View {
        if planQueue.state == .atGate,
           planQueue.currentPlanPath == docStore.relativePath(of: plan) {
            GateActionCard(workspaceID: session.workspace.id, mergeActionable: true, actions: gateActions)
        }
    }

    // MARK: - Mode B (plain workspace: no plan behind it)

    private func modeB() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                headerB()
                Divider()
                actionsRowB()
                if session.workspace.isMain {
                    Divider()
                    projectRunsSection()
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: session.workspace.id) {
            headStatus = await resolveWorktreeGitStatus(for: session.workspace)
        }
    }

    /// Branch name, linked repos, and working-tree status — the same
    /// data the header git chip shows for the *active* workspace
    /// (`ContentView.resolveGitStatus`), resolved here for *this*
    /// workspace specifically since the Overview can be any workspace's
    /// tab, active or not.
    private func headerB() -> some View {
        let flow: FlowStatus = headStatus.map {
            ($0.insertions > 0 || $0.deletions > 0) ? .running : .done
        } ?? .queued
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: FlowStatusGlyph.symbol(flow))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(FlowStatusGlyph.color(flow))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                Text(session.workspace.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if let headStatus {
                        Text(headStatus.shortSHA)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text("·").foregroundStyle(.tertiary)
                        if headStatus.insertions > 0 || headStatus.deletions > 0 {
                            Text("+\(headStatus.insertions)").foregroundStyle(.green)
                            Text("−\(headStatus.deletions)").foregroundStyle(.red)
                        } else {
                            Text("Clean")
                        }
                    }
                    if !session.workspace.linkedRepoIDs.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(session.workspace.linkedRepoIDs.joined(separator: " · "))
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }

    /// This workspace's worktree, resolved the same way the header chip
    /// resolves the *active* workspace's (`ContentView.resolveGitStatus`):
    /// first the linked repos' checkout of this branch, else (scratch
    /// workspaces) the first repo's default-branch checkout.
    private func resolveWorktreeGitStatus(for workspace: Workspace) async -> GitHeadStatus? {
        let repos = repoStore.repositories
        let candidates = workspace.linkedRepoIDs.isEmpty
            ? repos
            : repos.filter { workspace.linkedRepoIDs.contains($0.name) }
        guard let repo = candidates.first else { return nil }
        var worktree = await GitOperations.worktreeURL(forBranch: workspace.name, in: repo.rootURL)
        if worktree == nil {
            worktree = await GitOperations.worktreeURL(forBranch: repo.defaultBranch, in: repo.rootURL)
        }
        guard let worktree else { return nil }
        return await GitOperations.headStatus(in: worktree)
    }

    private func actionsRowB() -> some View {
        HStack(spacing: 12) {
            makeRunControls(session.workspace)
            Button(action: session.createTab) {
                Label("Open terminal", systemImage: "terminal")
            }
            .buttonStyle(.bordered)
            BranchChangesButton(workspaceID: session.workspace.id, actions: gateActions)
            Button(action: onNewPlan) {
                Label("Plan something here", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
    }

    // MARK: - Main's mini-dashboard (project runs, Group 3)

    /// Every active (non-merged) plan across the project as a compact
    /// run row, most-urgent first — `main`'s home turf, so it doubles
    /// as a project-wide status board.
    @ViewBuilder
    private func projectRunsSection() -> some View {
        let runs = ProjectRunsSummary.runs(
            plans: docStore.plans,
            status: { docStore.status(for: $0, featureExists: featureExists) },
            featureName: featureName,
            relativePath: { docStore.relativePath(of: $0) })
        VStack(alignment: .leading, spacing: 12) {
            Text("Project Runs")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.4)
                .textCase(.uppercase)
            if runs.isEmpty {
                Text("No active runs. Kick one off from a plan in the sidebar.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 6) {
                    ForEach(runs) { run in
                        projectRunRow(run)
                    }
                }
            }
        }
    }

    private func projectRunRow(_ run: ProjectRun) -> some View {
        let flow = flowStatus(for: run.status)
        return Button { openRun(run) } label: {
            HStack(spacing: 12) {
                Image(systemName: FlowStatusGlyph.symbol(flow))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlowStatusGlyph.color(flow))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 6) {
                        Text(run.status.label)
                        if run.total > 0 {
                            Text("·").foregroundStyle(.tertiary)
                            Text("\(run.checked)/\(run.total)")
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    if run.total > 0 {
                        ProgressView(value: Double(run.checked), total: Double(run.total))
                            .controlSize(.mini)
                            .frame(maxWidth: .infinity)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03)))
    }

    /// Resolve the row back to its `PlanDoc` (matched on `run.id`, the
    /// relative path `ProjectRunsSummary` derived it from) and hand off
    /// to the injected jump — this view never touches `WorkspaceStore`
    /// directly, matching every other action here.
    private func openRun(_ run: ProjectRun) {
        guard let plan = docStore.plans.first(where: { docStore.relativePath(of: $0) == run.id })
        else { return }
        onOpenRun(plan)
    }
}

/// The actions row's "View changes" affordance: the branch-vs-base diff
/// stat (fetched once on appearance, like `GateActionCard`) that opens the
/// same diff tab the gate card's "View diff" does — one path, reused.
private struct BranchChangesButton: View {
    let workspaceID: UUID
    let actions: FlowGateActions

    @State private var stat: GitBranchDiffStat?

    var body: some View {
        Button { actions.openDiff(workspaceID) } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.forwardslash.minus")
                Text("View changes")
                if let stat {
                    Text("+\(stat.insertions)").foregroundStyle(.green)
                    Text("−\(stat.deletions)").foregroundStyle(.red)
                }
            }
        }
        .buttonStyle(.bordered)
        .task { stat = await actions.fetchDiffStat(workspaceID) }
    }
}
