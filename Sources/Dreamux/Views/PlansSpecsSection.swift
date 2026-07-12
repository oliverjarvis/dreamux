import SwiftUI
import UniformTypeIdentifiers

/// Collapsible "Plans & Specs" sidebar section (rendered above the
/// Ad hoc group). Plans are the main item — grouped into initiatives,
/// carrying derived status + checkbox progress, and, once a worktree
/// exists, the workspace's controls (activate, run, merge, close);
/// unpaired specs surface as "needs plan"; genuinely loose docs sit
/// behind a Docs disclosure. Rows open docs in the workspace's editor
/// tabs.
struct PlansSpecsSection: View {
    @Bindable var docStore: DocStore
    @Bindable var layout: SidebarLayoutStore
    /// Live claude-session lanes, for the plan row's live status dot — old-style
    /// `ObservableObject` (unlike the `@Observable` stores above), so its own
    /// property wrapper.
    @ObservedObject var flows: FlowStore
    let featureExists: (String) -> Bool
    let onOpenDoc: (URL) -> Void
    /// Open a doc jumped to a 1-based line — phase/task rows open the
    /// plan at the clicked section.
    let onOpenDocAtLine: (URL, Int) -> Void
    let onRunPlan: (PlanDoc) -> Void
    let onNewPlan: () -> Void
    let onWritePlan: (PlanDoc) -> Void
    @Bindable var queue: PlanQueueController
    let onOpenFeature: (String) -> Void   // feature name → activate workspace
    let onEnqueue: (PlanDoc) -> Void
    /// The feature a plan runs (or ran) as — ledger record wins, else the
    /// name derived from the filename. Drives the → workspace affordance and
    /// the unread dot.
    let featureName: (PlanDoc) -> String?
    /// Whether the named feature's workspace has unread terminal output.
    let hasUnread: (String) -> Bool
    /// The runner state, so a plan row whose feature is live can reveal its
    /// run controls whenever a runner is up (not only on hover) and reflect
    /// their running/stopped state.
    let runners: RunnerManager
    /// The live workspace backing a feature name, or nil when it isn't in the
    /// sidebar — resolves the row's target for `makeRunControls`.
    let workspaceForFeature: (String) -> Workspace?
    /// Whether a workspace has a live plan-execution agent (its tracked agent
    /// terminal tab is open) — gates whether "Run plan" is offered.
    let hasLivePlanAgent: (Workspace) -> Bool
    /// Builds the shared run-control cluster for a workspace, wired to the
    /// sidebar's runner actions (see `WorkspaceSidebar.runControls(for:)`).
    let makeRunControls: (Workspace) -> HeaderRunControls
    /// Merge/Close pending channels — the plan-row context menu parks the
    /// target workspace id here; `WorkspaceSidebar` owns the merge sheet and
    /// close confirm-alert and consumes these exactly like the gate-merge
    /// channel. (The section never imports `ProjectSession`.)
    @Binding var gateMergeWorkspaceID: UUID?
    @Binding var gateCloseWorkspaceID: UUID?
    /// Enqueue the priority-worded course-correction nudge on the project's
    /// `PlanNudgeCenter` (the section never imports `ProjectSession`). Called
    /// only after the fix-task is written and only when the plan is running —
    /// idle plans get the tracked task and no nudge.
    let onCourseCorrectionNudge: (PlanDoc, _ summary: String, CorrectionPriority) -> Void
    /// The failure message of a fizzled auto-run launch for a plan
    /// relative path, if any — rendered as an orange row caption.
    let autoRunFailure: (String) -> String?
    /// The pinned main row: is the reserved main workspace currently
    /// the active one (selection styling)?
    let mainWorkspaceActive: Bool
    /// Non-nil when the last activation failed to materialize a
    /// default-branch worktree — rendered as a warning on the row.
    let mainWorktreeIssue: String?
    /// Activate (and lazily provision) the main workspace.
    let onOpenMain: () -> Void
    /// Display name for the pinned main row — the project's default
    /// branch name (e.g. "main").
    let mainBranchDisplayName: String
    /// Linked repo names shown in the row's subtitle when more than one
    /// repo is involved. Plain data — computed in `WorkspaceSidebar`.
    let mainRepoNames: [String]
    /// Live accessor for the reserved main workspace — nil until the
    /// first activation creates it. Resolves the row's target for
    /// `makeRunControls`.
    let mainWorkspace: () -> Workspace?

    @State private var docsExpanded = false
    @State private var hoveredDocURL: URL?
    @State private var hoveredChipURL: URL?
    /// User overrides of a multi-plan family's expansion, keyed by
    /// initiative id. Absence means "follow the default" — expanded while a
    /// child is in flight (see `isInitiativeExpanded`); once the user
    /// toggles, their choice sticks. Not persisted.
    @State private var initiativeExpansion: [String: Bool] = [:]
    @State private var hoveredInitiativeID: String?
    /// Queue row currently being dragged for reorder — see `queueSection`.
    @State private var draggingQueueItem: QueueItem?
    /// The row a *Course correct…* was fired from, driving the sheet. Only
    /// the plan-level entry (`.currentPhase`, on `planContextMenu`) lives
    /// here now — the task/phase-level entries moved to the workspace
    /// Overview's checklist along with the rest of the accordion (Task 6),
    /// which owns its own `correcting`/sheet for those two anchors.
    @State private var correcting: CorrectionTarget?
    /// Hover state for the pinned main row — reveals its run controls.
    @State private var mainRowHovered = false
    /// Hover state for the borderless "＋ New workspace" row.
    @State private var newWorkspaceHovered = false

    /// The plan + anchor + header a course correction is being filed
    /// against. Built at the clicked row — only the plan row (`.currentPhase`)
    /// builds one in this file now; see the doc comment on `correcting`.
    private struct CorrectionTarget: Identifiable {
        let id = UUID()
        let plan: PlanDoc
        let anchor: CourseCorrection.Anchor
        let description: String
    }

    var body: some View {
        // One section for every workspace: `main` (the base worktree) is the
        // first row, the run queue rides beneath it, and the plan-run cards
        // follow. `main` and the runs are the same kind of thing (a worktree
        // you can open), so they share one header — "Workspaces", not "Flows",
        // since `main` is not a run. The chevron collapses the whole section,
        // `main` included: a collapsed header that still showed `main` read as
        // half-collapsed, so it behaves like every other section here.
        VStack(alignment: .leading, spacing: 4) {
            header
            if layout.plansExpanded {
                mainRow
                queueSection()
                if docStore.plans.isEmpty && docStore.unpairedSpecs.isEmpty
                    && docStore.otherDocs.isEmpty {
                    emptyState
                } else {
                    rows
                }
                newWorkspaceRow
            }
        }
        .onAppear { docStore.startWatching() }
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

    /// Write the fix-task at the target's anchor, then — only for a plan with
    /// a live agent — enqueue the priority-worded nudge. The write happens
    /// immediately so the sidebar shows the new task; the clobber window
    /// against the running agent's own saves is documented and accepted on
    /// `CourseCorrection.apply`.
    private func submitCorrection(
        _ target: CorrectionTarget, text: String, priority: CorrectionPriority
    ) {
        correcting = nil
        let summary = CourseCorrection.summaryLine(from: text)
        let date = CourseCorrection.markerDate()
        try? CourseCorrection.apply(
            to: target.plan.fileURL, anchor: target.anchor,
            summary: summary, body: text, date: date)
        // Nudge only a running plan (its agent is live to receive it); idle
        // plans just get the tracked fix-task the write above added.
        let status = docStore.status(for: target.plan, featureExists: featureExists)
        if status == .running || status == .awaitingReview {
            onCourseCorrectionNudge(target.plan, summary, priority)
        }
    }

    // MARK: - Pieces

    private var header: some View {
        // Just the collapse control now — no per-header action icons. Docs
        // auto-rescan via `docStore.startWatching()` (no manual refresh), and
        // "New workspace" lives as a labelled row at the foot of the list.
        Button {
            withAnimation(.snappy(duration: 0.18)) { layout.plansExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(layout.plansExpanded ? 90 : 0))
                Text("Workspaces")
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    /// Borderless "＋ New workspace" row at the foot of the list — a plain
    /// plus (no circle, no box), highlighting only on hover, mirroring the
    /// Repositories section's add row. Opens a planning session, which mints
    /// the new run's workspace.
    private var newWorkspaceRow: some View {
        Button(action: onNewPlan) {
            HStack(spacing: 11) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
                Text("New workspace")
                    .font(.system(size: 15))
                Spacer(minLength: 0)
                Text("⌘P")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if newWorkspaceHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .padding(.horizontal, 4)
            }
        }
        .onHover { newWorkspaceHovered = $0 }
    }

    /// The permanent main-branch row — a place, not a plan: no status
    /// machinery, no close/merge, always present. Clicking activates
    /// the reserved main workspace (worktrees materialize on demand).
    @ViewBuilder
    private var mainRow: some View {
        Button {
            onOpenMain()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(mainWorktreeIssue == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mainBranchDisplayName)
                        .font(.system(size: 15, weight: mainWorkspaceActive ? .semibold : .medium))
                        .foregroundStyle(.primary)
                    if mainRepoNames.count > 1 {
                        Text(mainRepoNames.joined(separator: " · "))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let workspace = mainWorkspace() {
                    makeRunControls(workspace)
                        .opacity(mainRowHovered || runnersLive(for: workspace) ? 1 : 0)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(mainWorkspaceActive ? Color.primary.opacity(0.08)
                          : (mainRowHovered ? Color.primary.opacity(0.04) : .clear)))
        }
        .buttonStyle(.plain)
        .onHover { mainRowHovered = $0 }
        .help(mainWorktreeIssue ?? "Work on \(mainBranchDisplayName) — terminal, files, and services on the default branch")
    }

    /// Whether a runner is currently up on the given workspace's branch —
    /// mirrors the feature rows' `isRunning` check, so the pinned row keeps
    /// its run controls visible without hover while something is running.
    private func runnersLive(for workspace: Workspace) -> Bool {
        !runners.runningRunners(onBranch: workspace.name).isEmpty
    }

    private var emptyState: some View {
        Text("No specs or plans yet. “＋” starts a planning session that writes them to this project's docs/ folder.")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var rows: some View {
        let statuses = planStatuses()
        // Active initiatives (any non-merged plan), ordered by their
        // most-urgent plan so a running plan hoists its whole initiative.
        let active = docStore.initiatives
            .filter { hasActivePlan($0, statuses) }
            .sorted { initiativeRank($0, statuses) < initiativeRank($1, statuses) }
        let needsPlan = docStore.initiatives.filter(\.needsPlan)

        VStack(spacing: 2) {
            ForEach(active) { initiative in
                if initiative.plans.count > 1 {
                    multiPlanBlock(initiative, statuses: statuses)
                } else if let plan = initiative.plans.first {
                    planRow(plan, status: statuses[plan.fileURL] ?? .ready,
                            ordinal: nil, blockedBy: nil)
                }
            }
            ForEach(needsPlan) { initiative in
                if let spec = initiative.spec {
                    VStack(alignment: .leading, spacing: 2) {
                        specOnlyRow(spec)
                        // Carry the initiative's absorbed docs (a roadmap or
                        // notes that paired with the spec) onto the row —
                        // otherwise they'd be silently hidden.
                        let chips = supportingChips(for: initiative)
                        if !chips.isEmpty { chipLine(chips) }
                    }
                }
            }
            // Merged plans are intentionally NOT listed here — a done run is
            // archived to the Flows page, not kept in the Workspaces rail.
            if !docStore.looseDocs.isEmpty {
                disclosure("Docs (\(docStore.looseDocs.count))", isExpanded: $docsExpanded) {
                    ForEach(docStore.looseDocs) { doc in plainDocRow(doc) }
                }
            }
        }
    }

    private func planStatuses() -> [URL: PlanStatus] {
        Dictionary(uniqueKeysWithValues: docStore.plans.map {
            ($0.fileURL, docStore.status(for: $0, featureExists: featureExists))
        })
    }

    private func hasActivePlan(_ initiative: Initiative, _ statuses: [URL: PlanStatus]) -> Bool {
        initiative.plans.contains { statuses[$0.fileURL] != .merged }
    }

    /// An initiative sorts by its most-urgent plan — the same rank the flat
    /// plan list used, lifted to the initiative level.
    private func initiativeRank(_ initiative: Initiative, _ statuses: [URL: PlanStatus]) -> Int {
        initiative.plans.map { rank(statuses[$0.fileURL] ?? .ready) }.min() ?? rank(.ready)
    }

    // MARK: - Multi-plan family

    /// A multi-plan initiative: a grouping row (aggregate glyph, title,
    /// `plan k/n · pct`) with the doc-chip line beneath, and — when
    /// expanded — every phase as an indented child row carrying its
    /// ordinal, status, and a `blocked by k` annotation.
    @ViewBuilder
    private func multiPlanBlock(_ initiative: Initiative, statuses: [URL: PlanStatus]) -> some View {
        let memberStatuses = initiative.plans.map { statuses[$0.fileURL] ?? .ready }
        let progress = InitiativeProgress.resolve(
            statuses: memberStatuses,
            checked: initiative.plans.reduce(0) { $0 + $1.checkedSteps },
            total: initiative.plans.reduce(0) { $0 + $1.totalSteps })
        let expanded = isInitiativeExpanded(initiative, memberStatuses)
        let chips = docChips(for: initiative)
        VStack(alignment: .leading, spacing: 2) {
            initiativeGroupingRow(initiative, memberStatuses: memberStatuses,
                                  progress: progress, expanded: expanded)
            if !chips.isEmpty { chipLine(chips) }
            if expanded {
                ForEach(Array(initiative.plans.enumerated()), id: \.element.id) { index, plan in
                    // A merged phase is never "blocked" — the annotation is
                    // for the phases still waiting their turn.
                    let blockedBy = memberStatuses[index] == .merged
                        ? nil
                        : InitiativeProgress.blockingOrdinal(statuses: memberStatuses, index: index)
                    planRow(plan, status: memberStatuses[index],
                            ordinal: index + 1, blockedBy: blockedBy)
                        .padding(.leading, 14)
                }
            }
        }
    }

    private func initiativeGroupingRow(
        _ initiative: Initiative,
        memberStatuses: [PlanStatus],
        progress: (currentIndex: Int?, label: String, fraction: Double?),
        expanded: Bool
    ) -> some View {
        let anyRunning = memberStatuses.contains(.running)
        let glyph = progress.currentIndex == nil ? "checkmark.seal.fill" : "circle.lefthalf.filled"
        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                setInitiative(initiative.id, expanded: !expanded)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: chevronColumnWidth, height: 18)
                Image(systemName: glyph)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(anyRunning ? Color.green : Color.secondary)
                    .frame(width: 18)
                Text(initiative.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Text(progressSummary(progress))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if hoveredInitiativeID == initiative.id {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .padding(.horizontal, 4)
            }
        }
        .contextMenu {
            Button("Run remaining plans") { runRemaining(initiative, statuses: memberStatuses) }
        }
        .onHover { hovering in
            if hovering { hoveredInitiativeID = initiative.id }
            else if hoveredInitiativeID == initiative.id { hoveredInitiativeID = nil }
        }
    }

    /// `plan 2/3 · 41%` — the resolver's label plus a rounded percentage
    /// when the family carries checkboxes.
    private func progressSummary(_ progress: (currentIndex: Int?, label: String, fraction: Double?)) -> String {
        guard let fraction = progress.fraction else { return progress.label }
        return "\(progress.label) · \(Int((fraction * 100).rounded()))%"
    }

    /// Enqueue every non-merged phase in order — the grouping row's
    /// *Run remaining plans*. Blocking is presentational, so this walks the
    /// whole remaining sequence and lets the queue gate between them.
    private func runRemaining(_ initiative: Initiative, statuses: [PlanStatus]) {
        for (index, plan) in initiative.plans.enumerated() where statuses[index] != .merged {
            onEnqueue(plan)
        }
    }

    /// A family follows its default expansion (running/awaiting child, or
    /// the queue parked on one of its plans) until the user toggles it.
    private func isInitiativeExpanded(_ initiative: Initiative, _ memberStatuses: [PlanStatus]) -> Bool {
        if let override = initiativeExpansion[initiative.id] { return override }
        return InitiativeProgress.defaultsExpanded(
            statuses: memberStatuses,
            queueParkedOnMember: queueParked(on: initiative))
    }

    private func setInitiative(_ id: String, expanded: Bool) {
        initiativeExpansion[id] = expanded
    }

    /// Whether the queue sits at a gate/attention on one of the initiative's
    /// plans (matched by relative path).
    private func queueParked(on initiative: Initiative) -> Bool {
        guard queue.state == .atGate || queue.state == .attention,
              let current = queue.currentPlanPath else { return false }
        return initiative.plans.contains { docStore.relativePath(of: $0) == current }
    }

    /// Sidebar ordering: running → awaiting review → ready/in-progress
    /// (already date-sorted by the store) — merged handled separately.
    private func rank(_ status: PlanStatus) -> Int {
        switch status {
        case .running: return 0
        case .awaitingReview: return 1
        case .ready, .inProgress: return 2
        case .specOnly, .merged: return 3
        }
    }

    // MARK: - Queue

    @ViewBuilder
    private func queueSection() -> some View {
        if !queue.entries.isEmpty || queue.state != .idle {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Queue")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if queue.state == .idle {
                        Button("Start") { queue.start() }
                            .controlSize(.mini).buttonStyle(.bordered)
                            .disabled(queue.entries.isEmpty)
                    } else {
                        Button("Stop") { queue.stopQueue() }
                            .controlSize(.mini).buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 10)

                // `ForEach.onMove` needs `List` semantics to engage drag
                // reorder on macOS, and this queue lives in a plain
                // `VStack` (matching the rest of the section's chrome) —
                // so rows use the same `ReorderDropDelegate` pattern as
                // the feature rows (`WorkspaceSidebar.featureRow`)
                // instead, wrapping each path in `QueueItem` since the
                // delegate is generic over `Identifiable`.
                ForEach(queue.entries, id: \.self) { path in
                    queueRow(path)
                        .onDrag {
                            draggingQueueItem = QueueItem(path: path)
                            return NSItemProvider(object: path as NSString)
                        }
                        .onDrop(of: [.text], delegate: ReorderDropDelegate(
                            item: QueueItem(path: path),
                            items: queueItemsBinding,
                            dragging: $draggingQueueItem
                        ))
                }

                // The gate/attention card for the queue's current plan — the
                // per-plan run dashboard (Overview) also surfaces it, but the
                // queue box keeps its own copy so it's visible without
                // opening that workspace.
                gateCard()
            }
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04)))
        }
    }

    private func queueRow(_ path: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: path == queue.currentPlanPath
                  ? "arrowtriangle.right.fill" : "line.3.horizontal")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Text((path as NSString).lastPathComponent)
                .font(.caption)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                queue.remove(path)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(path == queue.currentPlanPath && queue.state != .idle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    /// The gate/attention action card for the queue's current plan — the
    /// queue box's own copy (the plan's workspace Overview carries the
    /// primary one).
    @ViewBuilder
    private func gateCard() -> some View {
        if let path = queue.currentPlanPath,
           queue.state == .atGate || queue.state == .attention {
            let feature = queue.featureNameForPlan(path)
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    queue.state == .atGate
                        ? "Plan complete — review before merging"
                        : (queue.lastError ?? "Session stalled with steps unchecked"),
                    systemImage: queue.state == .atGate
                        ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(queue.state == .atGate ? Color.green : .orange)
                HStack(spacing: 6) {
                    if let feature {
                        Button("Open feature") { onOpenFeature(feature) }
                    }
                    if queue.state == .atGate {
                        Button("Merge & Continue") { queue.mergeAndContinue() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Resume") { queue.resumeCurrent() }
                            .buttonStyle(.borderedProminent)
                        Button("Skip") { queue.skipCurrent() }
                    }
                }
                .controlSize(.mini)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Path-wrapping `Identifiable` used only to drive `ReorderDropDelegate`
    /// with `queue.entries` (a plain `[String]`).
    private struct QueueItem: Identifiable {
        let path: String
        var id: String { path }
    }

    /// Bridges the delegate's whole-array `Binding` to the controller's
    /// `move(fromOffsets:toOffset:)` — `queue.entries` is intentionally
    /// not directly settable from outside the controller, so each live
    /// reorder step fired by `ReorderDropDelegate.dropEntered` (as the
    /// drag crosses a sibling row) is translated into the equivalent
    /// single-item move and applied immediately, the same "commit as you
    /// go" persistence `queue.move` already has.
    private var queueItemsBinding: Binding<[QueueItem]> {
        Binding(
            get: { queue.entries.map(QueueItem.init) },
            set: { newItems in
                guard let dragging = draggingQueueItem,
                      let from = queue.entries.firstIndex(of: dragging.path),
                      let to = newItems.firstIndex(where: { $0.id == dragging.path })
                else { return }
                queue.move(fromOffsets: IndexSet(integer: from),
                           toOffset: to > from ? to + 1 : to)
            }
        )
    }

    /// Live claude-session status for this plan's workspace: ! waiting
    /// (needs you), ● running. Nothing when no live session lane exists.
    @ViewBuilder
    private func liveFlowDot(for workspace: Workspace?) -> some View {
        if let ws = workspace, let lane = preferredFlowLane(for: ws) {
            Image(systemName: FlowStatusGlyph.symbol(lane.status))
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(FlowStatusGlyph.color(lane.status))
                .help(lane.status == .waiting ? (lane.detail ?? "Waiting on you") : "claude busy")
        }
    }

    /// Among a workspace's ad hoc lanes, the one the dot should reflect:
    /// a waiting lane always wins over a running one — a workspace can
    /// carry more than one ad hoc lane (e.g. a finished one alongside a
    /// fresh one), and an older idle/running lane must never shadow a
    /// lane that actually needs the user.
    private func preferredFlowLane(for workspace: Workspace) -> Flow? {
        let candidates = flows.flows.filter { $0.workspaceID == workspace.id && $0.kind == .adhoc }
        return candidates.first { $0.status == .waiting } ?? candidates.first { $0.status == .running }
    }

    /// An active plan renders as a compact run card: the title gets a
    /// full-width line, the status/count a meta line, a full-width progress
    /// bar its own line, a one-line "current: …" step (`PlanCurrentStep`),
    /// and the primary actions (open, run/stop) a persistent bottom row —
    /// so the title never fights the controls for width and the actions
    /// don't hide behind hover. The full checklist lives on the workspace's
    /// Overview now; this card is just enough to see what's in flight and
    /// jump there. A single click activates the plan's workspace (and its
    /// Overview) when one exists, else opens the plan doc — a not-yet-run
    /// plan has no workspace to jump to.
    private func planRow(_ plan: PlanDoc, status: PlanStatus, ordinal: Int?, blockedBy: Int?) -> some View {
        let name = featureName(plan)
        let openableFeature = PlanWorkspacePresence.workspaceToOpen(
            status: status, featureName: name, featureExists: featureExists)
        // The unread dot tracks live output regardless of status — an agent
        // can produce output while parked at a gate — so it keys off the
        // feature existing, not the in-flight gate the → affordance uses.
        let showUnread = name.map { featureExists($0) && hasUnread($0) } ?? false
        let workspace = name.flatMap(workspaceForFeature)
        // A `**Runs:** after <blocker>` plan carries the blocker's title in
        // its caption (resolved via DocStore; `<filename> (missing)` when the
        // path doesn't resolve — never a silent drop).
        let afterCaption = IntakeEnactment.afterCaption(runsAfter: plan.runsAfter) { reference in
            let target = docStore.resolvedURL(forReference: reference)
            return docStore.docs.first { $0.fileURL.standardizedFileURL == target }?.title
        }
        // "Run the plan" is offered whenever the plan is incomplete AND no
        // agent is actually working it. Liveness is the app's own durable
        // signal — the tracked plan-agent terminal tab (`hasLivePlanAgent`) —
        // NOT the `.running` *status* (which only means the worktree exists)
        // nor the transient flow-event lane (lost on relaunch, oscillates
        // when the agent idles between turns). So a plan stuck at `.running`
        // with no agent tab can be re-run, and the button hides once a run
        // opens the agent.
        let hasLiveAgent = workspace.map(hasLivePlanAgent) ?? false
        let incomplete = status == .ready || status == .inProgress || status == .running
        let canRun = incomplete && !hasLiveAgent
        // Incomplete + a live agent = actively worked → show the running
        // spinner in the "Run plan" slot instead of the button.
        let isRunning = incomplete && hasLiveAgent
        let hasActions = workspace != nil || canRun
        let isHovered = hoveredDocURL == plan.fileURL

        return VStack(alignment: .leading, spacing: 7) {
            // Title + meta + progress + current step — the whole block
            // activates the workspace (or opens the doc pre-run).
            Button {
                if let name, workspace != nil {
                    onOpenFeature(name)
                } else {
                    onOpenDoc(plan.fileURL)
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: status.glyph)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(status == .running ? Color.green : Color.secondary)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            if let ordinal {
                                Text("\(ordinal) ·")
                                    .font(.callout.weight(.medium).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(plan.title)
                                .font(.system(size: 15, weight: .medium))
                                .lineLimit(1).truncationMode(.tail)
                            liveFlowDot(for: workspace)
                            if showUnread {
                                Circle().fill(Color.red).frame(width: 5, height: 5)
                            }
                            Spacer(minLength: 0)
                        }
                        planMetaLine(plan, blockedBy: blockedBy,
                                     afterCaption: afterCaption)
                        if plan.totalSteps > 0 {
                            planProgressBar(checked: plan.checkedSteps,
                                            total: plan.totalSteps)
                        }
                        if let current = PlanCurrentStep.label(for: plan) {
                            Text("Current: \(current)")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                planContextMenu(plan, canRun: canRun,
                                openableFeature: openableFeature, workspace: workspace)
            }

            if hasActions {
                planActionRow(plan, canRun: canRun, isRunning: isRunning, workspace: workspace)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .padding(.horizontal, 4)
            }
        }
        .onHover { hovering in
            if hovering { hoveredDocURL = plan.fileURL }
            else if hoveredDocURL == plan.fileURL { hoveredDocURL = nil }
        }
    }

    /// Exceptional annotations only — blocked/after/auto-run-failed. The
    /// status word moved to the leading glyph and the step count to the
    /// progress bar, so this line renders nothing for an ordinary plan.
    @ViewBuilder
    private func planMetaLine(
        _ plan: PlanDoc, blockedBy: Int?, afterCaption: String?
    ) -> some View {
        let failure = autoRunFailure(docStore.relativePath(of: plan))
        if blockedBy != nil || afterCaption != nil || failure != nil {
            HStack(spacing: 6) {
                if let blockedBy {
                    Text("blocked by \(blockedBy)")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let afterCaption {
                    Text(afterCaption)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
                if let failure {
                    // An unattended launch failed (name collision, no repos,
                    // …) — the mark sticks so it won't retry; say so.
                    Text("auto-run failed")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(failure)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The compact card's progress: a taller capsule bar with the checked/
    /// total count riding on its trailing edge.
    private func planProgressBar(checked: Int, total: Int) -> some View {
        let fraction = total > 0 ? Double(checked) / Double(total) : 0
        return HStack(spacing: 9) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            Text("\(checked)/\(total)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// The persistent action row under a plan card: Open (its workspace),
    /// the run/stop controls when a worktree exists, or a Run button when
    /// it's runnable but not yet provisioned. Right-aligned.
    @ViewBuilder
    private func planActionRow(
        _ plan: PlanDoc, canRun: Bool, isRunning: Bool, workspace: Workspace?
    ) -> some View {
        // The lime pill *runs the plan* (starts the claude agent), shown when
        // startable; once an agent is live it becomes a running spinner in
        // the same slot. `makeRunControls` is the separate run.toml
        // *services* control, shown once the workspace is materialized.
        HStack(spacing: 10) {
            if canRun {
                RunPlanButton { onRunPlan(plan) }
            } else if isRunning {
                RunningIndicator()
            }
            Spacer(minLength: 0)
            if let workspace {
                makeRunControls(workspace)
            }
        }
        // Align the row's leading edge with the title/progress column
        // (past the status glyph's 18pt frame + the row's 8pt spacing), so
        // "Run plan" lines up under the content instead of hanging out at
        // the card's edge.
        .padding(.leading, 26)
    }

    /// The plan card's context menu — the run/queue actions a runnable plan
    /// gets, plus course-correct and the workspace merge/close parity.
    @ViewBuilder
    private func planContextMenu(
        _ plan: PlanDoc, canRun: Bool, openableFeature: String?, workspace: Workspace?
    ) -> some View {
        if canRun {
            Button("Run Plan…") { onRunPlan(plan) }
            Button("Add to Queue") { onEnqueue(plan) }
            Divider()
        }
        // Plan-level correction: no natural anchor, so it lands in the phase
        // holding the current task (spec).
        Button("Course correct…") {
            correcting = CorrectionTarget(
                plan: plan, anchor: .currentPhase, description: plan.title)
        }
        Divider()
        if let feature = openableFeature {
            Button("Open workspace") { onOpenFeature(feature) }
        }
        if let workspace {
            if !workspace.linkedRepoIDs.isEmpty {
                Button("Merge…") { gateMergeWorkspaceID = workspace.id }
            }
            Divider()
            Button("Close \"\(workspace.name)\"", role: .destructive) {
                gateCloseWorkspaceID = workspace.id
            }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([plan.fileURL])
        }
    }

    /// Width of the leading column reserved for the multi-plan family's
    /// disclosure chevron (`initiativeGroupingRow`) — plan cards no longer
    /// have one of their own; the full checklist lives on the workspace's
    /// Overview now.
    private let chevronColumnWidth: CGFloat = 10

    // MARK: - Doc chips

    /// A compact, tappable label for an initiative-level doc.
    private struct Chip: Identifiable {
        let label: String
        let url: URL
        var id: URL { url }
    }

    private func docChips(for initiative: Initiative) -> [Chip] {
        var chips: [Chip] = []
        if let spec = initiative.spec {
            chips.append(Chip(label: DocChipLabel.label(title: spec.title, isSpec: true),
                              url: spec.fileURL))
        }
        chips.append(contentsOf: supportingChips(for: initiative))
        return chips
    }

    /// The initiative's supporting docs (roadmap, notes) as chips — the
    /// subset shown on a needs-plan row, whose spec is already the row.
    private func supportingChips(for initiative: Initiative) -> [Chip] {
        initiative.supportingDocs.map {
            Chip(label: DocChipLabel.label(title: $0.title, isSpec: false), url: $0.fileURL)
        }
    }

    private func chipLine(_ chips: [Chip]) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "paperclip")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            ForEach(Array(chips.enumerated()), id: \.element.id) { index, chip in
                if index > 0 {
                    Text("·").font(.caption2).foregroundStyle(.tertiary)
                }
                Button { onOpenDoc(chip.url) } label: {
                    Text(chip.label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .underline(hoveredChipURL == chip.url)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { hoveredChipURL = chip.url }
                    else if hoveredChipURL == chip.url { hoveredChipURL = nil }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 28)
        .padding(.trailing, 12)
        .padding(.bottom, 2)
    }

    private func specOnlyRow(_ spec: PlanDoc) -> some View {
        docRow(spec, canRun: false) {
            HStack(spacing: 8) {
                Image(systemName: PlanStatus.specOnly.glyph)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1).truncationMode(.tail)
                    Text("needs plan")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if hoveredDocURL == spec.fileURL {
                    Button("Write plan") { onWritePlan(spec) }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func plainDocRow(_ doc: PlanDoc) -> some View {
        docRow(doc, canRun: false) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                Text(doc.title)
                    .font(.callout)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
    }

    /// Row chrome shared by all three row types: click opens the doc,
    /// hover reveals Run for runnable plans, context menu everywhere.
    /// `trailing` adds a caller-supplied hover control (the → workspace
    /// button, run controls) stacked ahead of Run; `menu` adds caller-supplied
    /// context items ahead of Reveal in Finder. `keepTrailingVisible` pins the
    /// trailing area open when not hovered — the plan row uses it so a live
    /// runner's controls stay on screen, matching the feature rows.
    /// `hasRunControls` suppresses the hover Run circle when the caller already
    /// renders the runner controls' play/stop circle for this row (a `.ready`
    /// plan can still have a workspace during the ledger record-loss window),
    /// so two near-identical circles don't sit side by side — the agent-run
    /// action stays on the context menu, which `canRun` keeps.
    private func docRow<Body: View, Trailing: View, Menu: View>(
        _ doc: PlanDoc,
        canRun: Bool,
        keepTrailingVisible: Bool = false,
        hasRunControls: Bool = false,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder menu: () -> Menu = { EmptyView() },
        @ViewBuilder body: () -> Body
    ) -> some View {
        // The trailing controls are LAYOUT siblings of the row body, but
        // they're rendered UNCONDITIONALLY and only faded in/out — so the
        // body's width is identical hovered vs not, and the title never
        // reflows on hover. `keepTrailingVisible` keeps a live runner's
        // controls lit; anything else fades to zero opacity but keeps its
        // reserved space.
        let showTrailing = hoveredDocURL == doc.fileURL || keepTrailingVisible
        return HStack(spacing: 4) {
            Button { onOpenDoc(doc.fileURL) } label: {
                body()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if canRun {
                    Button("Run Plan…") { onRunPlan(doc) }
                    Button("Add to Queue") { onEnqueue(doc) }
                }
                menu()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([doc.fileURL])
                }
            }

            HStack(spacing: 4) {
                trailing()
                if canRun && !hasRunControls {
                    Button { onRunPlan(doc) } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    .help("Run this plan (provisions a worktree and starts claude)")
                }
            }
            .padding(.trailing, 12)
            .opacity(showTrailing ? 1 : 0)
            .allowsHitTesting(showTrailing)
        }
        .background {
            if hoveredDocURL == doc.fileURL {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .padding(.horizontal, 4)
            }
        }
        .onHover { hovering in
            if hovering { hoveredDocURL = doc.fileURL }
            else if hoveredDocURL == doc.fileURL { hoveredDocURL = nil }
        }
    }

    private func disclosure<C: View>(
        _ title: String, isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    Text(title).font(.caption2.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            if isExpanded.wrappedValue { content() }
        }
    }
}

// MARK: - Doc chip labeling

/// Pure labeling for an initiative's doc chips, kept out of the view so it
/// is unit-testable. The spec always reads `spec`; a supporting doc that
/// mentions a roadmap reads `roadmap`; otherwise the first word of its
/// title, lowercased.
enum DocChipLabel {
    static func label(title: String, isSpec: Bool) -> String {
        if isSpec { return "spec" }
        if title.range(of: "roadmap", options: .caseInsensitive) != nil { return "roadmap" }
        let firstWord = title.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return firstWord.lowercased()
    }
}

// MARK: - Run Plan confirm sheet

/// Confirm-and-configure before executing a plan: branch name (prefilled
/// from the plan filename) and repo selection (all linked by default) —
/// AddFeatureSheet's shape, scoped to a plan.
struct RunPlanSheet: View {
    let plan: PlanDoc
    let availableRepos: [Repository]
    let isResume: Bool
    let onSubmit: (_ branchName: String, _ repoIDs: [String]) -> Void
    let onCancel: () -> Void

    @State private var branchName: String
    @State private var selected: Set<String>

    init(plan: PlanDoc, initialBranch: String, availableRepos: [Repository], isResume: Bool,
         onSubmit: @escaping (_ branchName: String, _ repoIDs: [String]) -> Void,
         onCancel: @escaping () -> Void) {
        self.plan = plan
        self.availableRepos = availableRepos
        self.isResume = isResume
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _branchName = State(initialValue: initialBranch)
        _selected = State(initialValue: Set(availableRepos.map(\.name)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isResume ? "Resume Plan" : "Run Plan")
                .font(.title3.weight(.semibold))
            Text(plan.title)
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Branch / feature name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("branch", text: $branchName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isResume)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Repositories")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if availableRepos.isEmpty {
                    // Running provisions a worktree INSIDE a repo — with
                    // none, Run can never enable. Say so instead of
                    // presenting a silently dead button.
                    Label {
                        Text("This project has no repositories yet. Add one first — Repositories → ＋ in the sidebar (clone, import, or create a fresh one) — then run the plan into it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                ForEach(availableRepos, id: \.name) { repo in
                    Toggle(repo.name, isOn: Binding(
                        get: { selected.contains(repo.name) },
                        set: { on in
                            if on { selected.insert(repo.name) }
                            else { selected.remove(repo.name) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(isResume)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(isResume ? "Resume" : "Run") {
                    onSubmit(branchName.trimmingCharacters(in: .whitespaces),
                             Array(selected))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(branchName.trimmingCharacters(in: .whitespaces).isEmpty
                          || selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - New Plan sheet

/// Collects the idea, then the caller opens the planning terminal with
/// a brainstorming kickoff carrying it.
struct NewPlanSheet: View {
    /// The project this plan lands in — badged at the top of the sheet so
    /// it reads distinctly from ⌘N's app-global "New Project" sheet.
    let project: Project
    /// Per-project auto-run toggle (spec: Decisions §1). Bound to
    /// `SidebarLayoutStore.autoRunParallel` so a change persists immediately;
    /// default OFF. When ON, a discovered `**Runs:** parallel` plan launches
    /// itself instead of waiting for an explicit Run click.
    @Binding var autoRunParallel: Bool
    let onSubmit: (_ idea: String) -> Void
    let onCancel: () -> Void

    @State private var idea = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Plan")
                .font(.title3.weight(.semibold))
            SheetScopeBadge(icon: {
                ProjectGlyph(name: project.name, size: 14,
                             symbol: project.symbol, tint: project.glyphTint())
            }, text: "\(project.name) · this project only")
            Text("Describe the idea. A claude planning session opens in a project terminal, brainstorms it with you, and writes the spec and plan into this project's docs/ folder — they'll appear in the sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $idea)
                .font(.body)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.12)))
            HStack {
                Toggle("Run parallel plans automatically", isOn: $autoRunParallel)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Start Planning") {
                    onSubmit(idea.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Course-correct sheet

/// Files a course correction against a plan (spec: "Phase 2 — course
/// correction"). One sheet behind all three entry points — task row, phase
/// row, plan row — with the clicked row's `anchorDescription` in the header.
/// The typed observation becomes a tracked fix-task under the anchor phase
/// (its first line the heading, the whole text the step body), and the
/// picked priority words the nudge a running plan's agent receives.
struct CourseCorrectSheet: View {
    /// Human description of the anchor the fix-task attaches to — a task
    /// title, a phase name, or the plan title (rendered under the header).
    let anchorDescription: String
    /// Submit with the raw typed text and the chosen delivery priority; the
    /// caller derives the summary, writes the fix-task, and nudges.
    let onSubmit: (_ text: String, _ priority: CorrectionPriority) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    // Default Fix next: finish the current task cleanly, then the fix.
    @State private var priority: CorrectionPriority = .next

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Course correct")
                .font(.title3.weight(.semibold))
            Text(anchorDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("Describe what's wrong or what to change. It becomes a tracked fix-task in the plan; if the plan is running, its agent is nudged with the priority you pick.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.12)))
            Picker("Delivery", selection: $priority) {
                ForEach(CorrectionPriority.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                // Submit is disabled on empty/whitespace input: the fix-task
                // writer builds a malformed heading from a blank summary.
                Button("Send") { onSubmit(text, priority) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
