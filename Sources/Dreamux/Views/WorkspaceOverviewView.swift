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
    /// Live flow state, passed as a plain reference and re-wrapped as an
    /// `@ObservedObject` on the view (a struct field can't be observed).
    let flows: FlowStore
    /// Zoom the Flows page to a workspace's run lane (the "Working now"
    /// pill's click target). ContentView resolves the workspace's plan lane
    /// — the session lane the subagent lives on is board-suppressed.
    let onOpenRunFlow: (UUID) -> Void
    /// GitHub PR lifecycle for a tracked feature name — backed by
    /// `session.prStatus.state(for:)` (Task 8), mapped to `PRLaneState`
    /// (`ContentView`'s own `prState(forFeature:)`, the same shape
    /// `prStatesByWorkspace` re-keys for the Flows board). `nil` when the
    /// feature isn't tracked or has no known PR. Used by main's
    /// mini-dashboard row (`projectRunRow`), keyed on `ProjectRun.featureName`.
    let prState: (String) -> PRLaneState?
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
    /// The project's live flow state — read reactively so the Overview's
    /// "Working now" strip updates as subagents start and stop. Carried by
    /// `WorkspaceOverviewDependencies` (a plain reference) and re-wrapped
    /// here so `@Published flows` drives re-render.
    @ObservedObject var flows: FlowStore
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
    /// Zoom the Flows page to this workspace's run lane — the pill's click
    /// target. See `WorkspaceOverviewDependencies.onOpenRunFlow`.
    let onOpenRunFlow: (UUID) -> Void
    /// See `WorkspaceOverviewDependencies.prState`.
    let prState: (String) -> PRLaneState?

    /// Mode B's working-tree summary — loaded once on appear (no poller;
    /// unlike the header chip's 5s loop, this tab isn't always on
    /// screen), keyed to the workspace so it reloads if this view instance
    /// ever gets reused for a different workspace.
    @State private var headStatus: GitHeadStatus?
    /// Task row currently under the pointer — drives the hover-revealed
    /// "View changes" button, keyed by the task's line (mirrors the
    /// rail's now-deleted `hoveredTaskLine`).
    @State private var hoveredTaskLine: Int?
    /// Step row currently under the pointer within an expanded task — drives
    /// the per-step hover wash, keyed by the step's document line.
    @State private var hoveredStepLine: Int?
    /// Task rows currently expanded to reveal their steps, keyed by the
    /// task's line. The current task auto-expands once on open (see
    /// `modeA`'s `.onAppear`); every other task starts collapsed so the
    /// checklist reads as a scannable outline until you drill in.
    @State private var expandedTaskLines: Set<Int> = []
    /// Whether the one-time current-task auto-expand has run for this view
    /// instance. A plain `isEmpty` guard would re-seed if the user collapsed
    /// the auto-expanded task and expanded nothing else; this fires the seed
    /// exactly once so a deliberate collapse always sticks.
    @State private var didSeedExpansion = false
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
        // The workspace exists (we're rendering its tab), so `featureExists`
        // is trivially true here.
        let status = docStore.status(for: plan, featureExists: { _ in true })
        let hero = RunHeroState.resolve(status: status, hasLiveAgent: hasLiveAgent(session.workspace))
        let tasks = plan.tasks.filter { !$0.steps.isEmpty }
        let live = OverviewLiveAgents.subagents(
            in: flows.flows, workspaceID: session.workspace.id, tasks: plan.tasks)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroCard(plan, hero: hero)
                if !live.isEmpty {
                    workingNow(plan, subagents: live)
                }
                OverviewSectionLabel(title: "Tasks", trailing: "\(tasks.count) tasks")
                checklist(plan, live: live)
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // Auto-expand the current task the first time this Overview
            // appears — the one row you most want to see steps for — while
            // leaving the rest collapsed. Fires exactly once (guarded on
            // `didSeedExpansion`, not on emptiness) so a later collapse of
            // that row is never undone by a re-appear.
            guard !didSeedExpansion else { return }
            didSeedExpansion = true
            if let line = currentTaskLine(plan) {
                expandedTaskLines.insert(line)
            }
        }
    }

    /// Line of the first task carrying an unchecked step — the run's
    /// current task, and the one `modeA` auto-expands on open.
    private func currentTaskLine(_ plan: PlanDoc) -> Int? {
        plan.tasks
            .filter { !$0.steps.isEmpty }
            .first { $0.steps.contains { !$0.checked } }?
            .line
    }

    /// The "Working now" strip: a pill per live subagent. Horizontal scroll
    /// is a safe fallback for the rare overflow (done agents are collapsed
    /// upstream, so live ones are few). Hidden entirely when `subagents` is
    /// empty (caller guards).
    private func workingNow(_ plan: PlanDoc, subagents: [LiveSubagent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            OverviewSectionLabel(title: "Working now")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(subagents) { sub in
                        LiveSubagentPill(subagent: sub, detail: detailText(for: sub, plan: plan)) {
                            onOpenRunFlow(session.workspace.id)
                        }
                    }
                }
            }
        }
    }

    /// Prefer the pinned task's clean title (so the pill and the badged row
    /// agree); fall back to the subagent's live activity.
    private func detailText(for sub: LiveSubagent, plan: PlanDoc) -> String? {
        if let line = sub.taskLine, let task = plan.tasks.first(where: { $0.line == line }) {
            return cleanTitle(task.title)
        }
        return sub.activity
    }

    // MARK: - Mode A hero

    private func heroCard(_ plan: PlanDoc, hero: RunHeroState) -> some View {
        let startedAt = docStore.ledger.recordForPlan(docStore.relativePath(of: plan))?.startedAt
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                OverviewStatusPill(text: hero.pillText, flow: hero.flow,
                                   pulse: hero.phase == .running)
                Spacer(minLength: 0)
                if let startedAt {
                    (Text("Started ") + Text(startedAt, style: .relative) + Text(" ago"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                }
                makeRunControls(session.workspace)
            }
            Text(plan.title)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 13)
            heroMeta(plan)
                .padding(.top, 9)
            if plan.totalSteps > 0 {
                heroProgress(plan, complete: hero.progressComplete)
                    .padding(.top, 17)
            }
            if hero.phase == .merged {
                mergedNote()
                    .padding(.top, 16)
            }
            heroActions(plan, hero: hero)
                .padding(.top, 16)
        }
        .overviewSurface(padding: 20)
    }

    private func heroMeta(_ plan: PlanDoc) -> some View {
        let chips = docChips(for: plan)
        return HStack(spacing: 9) {
            Label(session.workspace.name, systemImage: "arrow.triangle.branch")
                .labelStyle(.titleAndIcon)
            if !session.workspace.linkedRepoIDs.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(session.workspace.linkedRepoIDs.joined(separator: " · "))
            }
            if !chips.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Image(systemName: "paperclip").font(.system(size: 11)).foregroundStyle(.tertiary)
                ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                    if index > 0 { Text("·").foregroundStyle(.tertiary) }
                    Button { onOpenDoc(chip.url) } label: {
                        Text(chip.label).underline()
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func heroProgress(_ plan: PlanDoc, complete: Bool) -> some View {
        let fraction = Double(plan.checkedSteps) / Double(max(1, plan.totalSteps))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(plan.checkedSteps) / \(plan.totalSteps) steps")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(complete ? Color.green : Color.secondary)
                Spacer(minLength: 0)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            OverviewProgressBar(fraction: fraction, complete: complete)
        }
    }

    private func mergedNote() -> some View {
        // The base is this workspace's first *linked* repo's default branch
        // (mirrors `resolveWorktreeGitStatus`' repo pick) — not just the
        // store's first repo, which would name the wrong base for a
        // workspace that links a non-first repo.
        let base = (session.workspace.linkedRepoIDs.isEmpty
                    ? repoStore.repositories.first
                    : repoStore.repositories.first {
                        session.workspace.linkedRepoIDs.contains($0.name)
                    })?.defaultBranch ?? "main"
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.green)
            Text("Merged — this run's changes are on \(base).")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func heroActions(_ plan: PlanDoc, hero: RunHeroState) -> some View {
        HStack(spacing: 10) {
            switch hero.primary {
            case .run:
                RunPlanButton { onRunPlan(plan) }
            case .running:
                RunningIndicator()
            case .reviewAndMerge:
                Button {
                    gateActions.requestMerge(session.workspace.id)
                } label: {
                    Label(mergePrimaryLabel(plan), systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
            case .noPrimary:
                EmptyView()
            }
            BranchChangesButton(workspaceID: session.workspace.id, actions: gateActions)
            Button(action: openOrFocusTerminal) {
                Label("Open terminal", systemImage: "terminal")
            }
            .buttonStyle(.soft)
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
    }

    /// "Merge & continue" when this plan is the queue's current gate (so the
    /// queue advances), else "Review & merge". Both call the same
    /// `gateActions.requestMerge`, which itself routes queue-gated vs. off-queue.
    private func mergePrimaryLabel(_ plan: PlanDoc) -> String {
        if planQueue.state == .atGate,
           planQueue.currentPlanPath == docStore.relativePath(of: plan) {
            return "Merge & continue"
        }
        return "Review & merge"
    }

    /// `PlanStatus` → `FlowStatus`, so the header can reuse
    /// `FlowStatusGlyph` (Global Constraint: shared status glyph/color
    /// vocabulary) instead of inventing its own tint rules.
    private func flowStatus(for status: PlanStatus) -> FlowStatus {
        status.flowStatus
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
    private func checklist(_ plan: PlanDoc, live: [LiveSubagent]) -> some View {
        let tasks = plan.tasks.filter { !$0.steps.isEmpty }
        // Global 1-based task numbers, keyed by line (unique per task in
        // practice; `uniquingKeysWith` keeps the first rather than trapping
        // if a malformed plan ever repeats a line).
        let numbers = Dictionary(tasks.enumerated().map { ($1.line, $0 + 1) },
                                 uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: PlanPhases.shouldGroup(tasks) ? 14 : 2) {
            if PlanPhases.shouldGroup(tasks) {
                let groups = PlanPhases.groups(tasks)
                let currentGroup = PlanPhases.currentGroupIndex(groups)
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    phaseSection(group, plan: plan, numbers: numbers,
                                 isCurrentGroup: index == currentGroup, live: live)
                }
            } else {
                let currentIndex = tasks.firstIndex { $0.steps.contains { !$0.checked } }
                ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                    taskRow(task, number: index + 1, plan: plan,
                            isCurrent: index == currentIndex, live: live)
                }
            }
        }
        .overviewSurface(padding: 8)
    }

    private func phaseSection(
        _ group: PlanPhases.Group, plan: PlanDoc, numbers: [Int: Int],
        isCurrentGroup: Bool, live: [LiveSubagent]
    ) -> some View {
        let currentTaskIndex = group.tasks.firstIndex { $0.steps.contains { !$0.checked } }
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                if let line = group.tasks.first?.phaseLine ?? group.tasks.first?.line {
                    onOpenDocAtLine(plan.fileURL, line)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(group.phase ?? "Steps")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    if isCurrentGroup { currentTag() }
                    Spacer(minLength: 0)
                    Text("\(group.checkedSteps)/\(group.totalSteps)")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
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
            ForEach(Array(group.tasks.enumerated()), id: \.offset) { index, task in
                taskRow(task, number: numbers[task.line] ?? (index + 1),
                        plan: plan, isCurrent: index == currentTaskIndex, live: live)
            }
        }
    }

    private func taskRow(
        _ task: PlanTask, number: Int, plan: PlanDoc, isCurrent: Bool, live: [LiveSubagent]
    ) -> some View {
        let checked = task.steps.filter(\.checked).count
        let total = task.steps.count
        let allChecked = checked == total
        let isExpanded = expandedTaskLines.contains(task.line)
        let pinned = live.first { $0.taskLine == task.line }
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleExpanded(task.line)
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    Text("\(number)")
                        .font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, alignment: .trailing)
                    checkGlyph(allChecked: allChecked, isCurrent: isCurrent)
                    Text(cleanTitle(task.title))
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.tail)
                    if isCurrent { currentTag() }
                    if let pinned {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(FlowStatusGlyph.color(pinned.status))
                                .frame(width: 6, height: 6)
                            Text(pinned.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
                        .help("\(pinned.name) is working this task")
                    }
                    Spacer(minLength: 0)
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
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05)))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent
                          ? Color.accentColor.opacity(0.08)
                          : (hoveredTaskLine == task.line ? Color.primary.opacity(0.04) : Color.clear))
            }
            .contextMenu {
                Button("Open in plan") { onOpenDocAtLine(plan.fileURL, task.line) }
                Button("View changes") { onViewTaskChanges(plan, task) }
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
            if isExpanded {
                stepsList(task, plan: plan)
            }
        }
    }

    /// The task's steps, revealed when its row is expanded. Each step is a
    /// first-class row — generous vertical padding, a hover wash, and a click
    /// that opens the plan at that checkbox's line (steps carry their own
    /// `line` now). The title wraps rather than truncating, since a step line
    /// can be a full sentence. Indented so the glyph column lines up under
    /// the task's status glyph above it.
    private func stepsList(_ task: PlanTask, plan: PlanDoc) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(task.steps.enumerated()), id: \.offset) { _, step in
                Button {
                    onOpenDocAtLine(plan.fileURL, step.line)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 11) {
                        Image(systemName: step.checked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12.5))
                            .foregroundStyle(step.checked ? Color.green : Color.secondary)
                            .frame(width: 18)
                        Text(step.title)
                            .font(.system(size: 14))
                            .foregroundStyle(step.checked ? .secondary : .primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hoveredStepLine == step.line
                              ? Color.primary.opacity(0.05) : Color.clear)
                }
                .onHover { inside in
                    if inside { hoveredStepLine = step.line }
                    else if hoveredStepLine == step.line { hoveredStepLine = nil }
                }
                .help("Open this step in the plan")
            }
        }
        .padding(.leading, 31)
        .padding(.trailing, 10)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    /// Flip a task row between collapsed and expanded, animated so the
    /// chevron rotation and the steps' reveal move together.
    private func toggleExpanded(_ line: Int) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if expandedTaskLines.contains(line) {
                expandedTaskLines.remove(line)
            } else {
                expandedTaskLines.insert(line)
            }
        }
    }

    /// A leading "Task 12:" is redundant once a number badge carries the
    /// index — strip it; keep any other title verbatim.
    private func cleanTitle(_ title: String) -> String { PlanTaskTitle.clean(title) }

    @ViewBuilder
    private func checkGlyph(allChecked: Bool, isCurrent: Bool) -> some View {
        if allChecked {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.green)
                .frame(width: 19, height: 19)
                .background(Circle().fill(Color.green.opacity(0.16)))
        } else if isCurrent {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 19, height: 19)
        } else {
            Image(systemName: "circle")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .frame(width: 19, height: 19)
        }
    }

    private func currentTag() -> some View {
        Text("current")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
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

    // MARK: - Mode B (plain workspace: no plan behind it)

    private func modeB() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerB()
                if session.workspace.isMain {
                    OverviewSectionLabel(title: "Project Runs")
                    projectRunsSection()
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: session.workspace.id) {
            headStatus = await resolveWorktreeGitStatus(for: session.workspace)
        }
    }

    private func headerB() -> some View {
        let pill = OverviewModeBStatus.pill(
            insertions: headStatus?.insertions, deletions: headStatus?.deletions)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let pill {
                    OverviewStatusPill(text: pill.text, flow: pill.flow)
                }
                Spacer(minLength: 0)
                makeRunControls(session.workspace)
            }
            Text(session.workspace.name)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.top, 13)
            HStack(spacing: 9) {
                if let headStatus {
                    Text(headStatus.shortSHA)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if headStatus.insertions > 0 || headStatus.deletions > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("+\(headStatus.insertions)").foregroundStyle(.green)
                        Text("−\(headStatus.deletions)").foregroundStyle(.red)
                    }
                }
                if !session.workspace.linkedRepoIDs.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(session.workspace.linkedRepoIDs.joined(separator: " · "))
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.top, 9)
            actionsRowB()
                .padding(.top, 16)
        }
        .overviewSurface(padding: 20)
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
        HStack(spacing: 10) {
            Button(action: onNewPlan) {
                Label("Plan something here", systemImage: "sparkles")
            }
            .buttonStyle(.soft)
            Button(action: session.createTab) {
                Label("Open terminal", systemImage: "terminal")
            }
            .buttonStyle(.soft)
            BranchChangesButton(workspaceID: session.workspace.id, actions: gateActions)
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
    }

    // MARK: - Main's mini-dashboard (project runs)

    @ViewBuilder
    private func projectRunsSection() -> some View {
        let runs = ProjectRunsSummary.runs(
            plans: docStore.plans,
            status: { docStore.status(for: $0, featureExists: featureExists) },
            featureName: featureName,
            relativePath: { docStore.relativePath(of: $0) })
        if runs.isEmpty {
            Text("No active runs. Kick one off from a plan in the sidebar.")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .overviewSurface(padding: 16)
        } else {
            VStack(spacing: 4) {
                ForEach(runs) { run in
                    projectRunRow(run)
                }
            }
            .overviewSurface(padding: 8)
        }
    }

    private func projectRunRow(_ run: ProjectRun) -> some View {
        let flow = flowStatus(for: run.status)
        let complete = run.total > 0 && run.checked == run.total
        let pr = run.featureName.flatMap(prState)
        return Button { openRun(run) } label: {
            HStack(spacing: 12) {
                Image(systemName: FlowStatusGlyph.symbol(flow))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlowStatusGlyph.color(flow))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(run.title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.tail)
                        if let pr {
                            PRStatusBadge(state: pr)
                        }
                    }
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
                        OverviewProgressBar(
                            fraction: Double(run.checked) / Double(max(1, run.total)),
                            complete: complete)
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
        .buttonStyle(.soft)
        .task { stat = await actions.fetchDiffStat(workspaceID) }
    }
}
