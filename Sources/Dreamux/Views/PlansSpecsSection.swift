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
    /// Builds the shared run-control cluster for a workspace, wired to the
    /// sidebar's runner actions (see `WorkspaceSidebar.runControls(for:)`).
    let makeRunControls: (Workspace) -> WorkspaceRunControls
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

    @State private var doneExpanded = false
    @State private var docsExpanded = false
    @State private var hoveredDocURL: URL?
    @State private var hoveredChipURL: URL?
    /// Plan rows expanded to their task list, keyed by plan file path.
    /// Deliberately not persisted — a per-session affordance.
    @State private var expandedPlans: Set<String> = []
    /// User overrides of a phase group's expansion inside a plan's task
    /// list, keyed by `<plan path>#<phase>`. Absence means "follow the
    /// default" — only the phase holding the current task starts open.
    /// Not persisted.
    @State private var expandedPhaseOverrides: [String: Bool] = [:]
    /// User overrides of a multi-plan family's expansion, keyed by
    /// initiative id. Absence means "follow the default" — expanded while a
    /// child is in flight (see `isInitiativeExpanded`); once the user
    /// toggles, their choice sticks. Not persisted.
    @State private var initiativeExpansion: [String: Bool] = [:]
    @State private var hoveredInitiativeID: String?
    /// Queue row currently being dragged for reorder — see `queueSection`.
    @State private var draggingQueueItem: QueueItem?
    /// The row a *Course correct…* was fired from, driving the sheet. One
    /// sheet behind all three entry points; the case carries the anchor.
    @State private var correcting: CorrectionTarget?

    /// The plan + anchor + header a course correction is being filed against.
    /// Built at the clicked row (task / phase / plan), consumed on submit.
    private struct CorrectionTarget: Identifiable {
        let id = UUID()
        let plan: PlanDoc
        let anchor: CourseCorrection.Anchor
        let description: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if layout.plansExpanded {
                if docStore.plans.isEmpty && docStore.unpairedSpecs.isEmpty
                    && docStore.otherDocs.isEmpty {
                    emptyState
                } else {
                    rows
                }
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
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { layout.plansExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(layout.plansExpanded ? 90 : 0))
                    Text("Plans & Specs")
                        .font(.system(size: 12, weight: .semibold))
                        .kerning(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { docStore.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rescan docs")

            Button(action: onNewPlan) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New plan… (opens a planning session)")
        }
        .padding(.bottom, 2)
    }

    private var emptyState: some View {
        Text("No specs or plans yet. “＋” starts a planning session that writes them to this project's docs/ folder.")
            .font(.caption2)
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
        // Merged plans fold into the shared Done disclosure — except the
        // merged phases of an active multi-plan family, which render as
        // children under their grouping row instead of being double-listed.
        let claimed = familyMemberURLs(active)
        let done = docStore.plans.filter {
            statuses[$0.fileURL] == .merged && !claimed.contains($0.fileURL)
        }

        VStack(spacing: 2) {
            queueSection(showGateFallback: !isGateAnchoredToRenderedRow(active, statuses))
            ForEach(active) { initiative in
                if initiative.plans.count > 1 {
                    multiPlanBlock(initiative, statuses: statuses)
                } else if let plan = initiative.plans.first {
                    planBlock(plan,
                              status: statuses[plan.fileURL] ?? .ready,
                              ordinal: nil,
                              chips: docChips(for: initiative),
                              blockedBy: nil)
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
            if !done.isEmpty {
                disclosure("Done (\(done.count))", isExpanded: $doneExpanded) {
                    ForEach(done) { plan in
                        planBlock(plan, status: .merged, ordinal: nil, chips: [], blockedBy: nil)
                    }
                }
            }
            if !docStore.looseDocs.isEmpty {
                disclosure("Docs (\(docStore.looseDocs.count))", isExpanded: $docsExpanded) {
                    ForEach(docStore.looseDocs) { doc in plainDocRow(doc) }
                }
            }
        }
    }

    /// File URLs of every plan owned by an active multi-plan family — the
    /// rows the grouping level renders itself, kept out of the flat Done list.
    private func familyMemberURLs(_ active: [Initiative]) -> Set<URL> {
        Set(active.filter { $0.plans.count > 1 }.flatMap { $0.plans.map(\.fileURL) })
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
                    planBlock(plan,
                              status: memberStatuses[index],
                              ordinal: index + 1,
                              chips: [],
                              blockedBy: blockedBy)
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
    private func queueSection(showGateFallback: Bool) -> some View {
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

                // The gate/attention card normally anchors to the plan row
                // it concerns (see `planBlock`); this is the fallback copy
                // for when that row isn't on screen (family collapsed, or
                // the plan isn't in the doc scan).
                if showGateFallback { gateCard() }
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

    /// The gate/attention action card for the queue's current plan. Rendered
    /// either inline under the plan row it concerns (`planBlock`) or, when
    /// that row isn't visible, as a fallback inside the queue box.
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

    /// A plan row plus the pieces that hang beneath it: the doc-chip line
    /// (first plan of an initiative), the queue gate card when this is the
    /// current plan, and, when expanded, its task rows.
    @ViewBuilder
    private func planBlock(
        _ plan: PlanDoc, status: PlanStatus, ordinal: Int?, chips: [Chip], blockedBy: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            planRow(plan, status: status, ordinal: ordinal, blockedBy: blockedBy)
            if !chips.isEmpty { chipLine(chips) }
            if shouldAnchorGate(under: plan, status: status) { gateCard() }
            if expandedPlans.contains(plan.fileURL.path) { planTasks(plan) }
        }
    }

    private func planRow(_ plan: PlanDoc, status: PlanStatus, ordinal: Int?, blockedBy: Int?) -> some View {
        let name = featureName(plan)
        let openableFeature = PlanWorkspacePresence.workspaceToOpen(
            status: status, featureName: name, featureExists: featureExists)
        // The unread dot tracks live output regardless of status — an agent
        // can produce output while parked at a gate — so it keys off the
        // feature existing, not the in-flight gate the → affordance uses.
        let showUnread = name.map { featureExists($0) && hasUnread($0) } ?? false
        // The live workspace behind this plan (nil until its worktree exists),
        // and whether a runner is up on it — run controls ride alongside the →
        // affordance and, like feature rows, stay visible while running.
        let workspace = name.flatMap(workspaceForFeature)
        let runnerRunning = workspace.map { !runners.runningRunners(onBranch: $0.name).isEmpty } ?? false
        // A `**Runs:** after <blocker>` plan carries the blocker's title in
        // its caption (resolved via DocStore; `<filename> (missing)` when the
        // path doesn't resolve — never a silent drop).
        let afterCaption = IntakeEnactment.afterCaption(runsAfter: plan.runsAfter) { reference in
            let target = docStore.resolvedURL(forReference: reference)
            return docStore.docs.first { $0.fileURL.standardizedFileURL == target }?.title
        }
        // The disclosure chevron overlays the row's leading gap rather than
        // nesting inside its open-doc button — the same on-top idiom the
        // feature rows use for their hover controls, so a click on the
        // chevron toggles tasks without opening the doc.
        return ZStack(alignment: .leading) {
            docRow(
                plan,
                canRun: status == .ready || status == .inProgress,
                keepTrailingVisible: runnerRunning,
                hasRunControls: workspace != nil,
                trailing: {
                    if let feature = openableFeature {
                        Button { onOpenFeature(feature) } label: {
                            Image(systemName: "arrow.right.circle")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(feature)'s workspace")
                    }
                    if let workspace {
                        makeRunControls(workspace)
                    }
                },
                menu: {
                    // Plan-level correction: no natural anchor, so it lands
                    // in the phase holding the current task (spec).
                    Button("Course correct…") {
                        correcting = CorrectionTarget(
                            plan: plan, anchor: .currentPhase, description: plan.title)
                    }
                    Divider()
                    if let feature = openableFeature {
                        Button("Open workspace") { onOpenFeature(feature) }
                    }
                    // Merge/Close parity with the feature rows, for any plan
                    // whose feature workspace is live — routed through the
                    // sidebar's sheet/alert channels (see featureMenu).
                    if let workspace {
                        if !workspace.linkedRepoIDs.isEmpty {
                            Button("Merge…") { gateMergeWorkspaceID = workspace.id }
                        }
                        Divider()
                        Button("Close \"\(workspace.name)\"", role: .destructive) {
                            gateCloseWorkspaceID = workspace.id
                        }
                    }
                }
            ) {
                HStack(spacing: 8) {
                    Color.clear.frame(width: chevronColumnWidth, height: 18)
                    Image(systemName: status.glyph)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(status == .running ? Color.green : Color.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if let ordinal {
                                Text("\(ordinal) ·")
                                    .font(.callout.weight(.medium).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(plan.title)
                                .font(.callout.weight(.medium))
                                .lineLimit(1).truncationMode(.tail)
                            if showUnread {
                                Circle().fill(Color.red).frame(width: 5, height: 5)
                            }
                        }
                        HStack(spacing: 6) {
                            Text(status.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if plan.totalSteps > 0 {
                                ProgressView(value: Double(plan.checkedSteps),
                                             total: Double(plan.totalSteps))
                                    .controlSize(.mini)
                                    .frame(width: 60)
                                Text("\(plan.checkedSteps)/\(plan.totalSteps)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            if let blockedBy {
                                Text("· blocked by \(blockedBy)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if let afterCaption {
                                Text("· \(afterCaption)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if let failure = autoRunFailure(docStore.relativePath(of: plan)) {
                                // An unattended launch failed (name
                                // collision, no repos, …) — the mark
                                // sticks so it won't retry; say so
                                // instead of an unexplained `ready`.
                                Text("· auto-run failed")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .help(failure)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            if !renderableTasks(plan).isEmpty {
                planDisclosure(plan).padding(.leading, 10)
            }
        }
    }

    /// Width of the leading column reserved for the disclosure chevron. The
    /// overlaid chevron sits inside it (row content padding + this width),
    /// so a plan with no tasks still aligns with one that has them.
    private let chevronColumnWidth: CGFloat = 10

    private func planDisclosure(_ plan: PlanDoc) -> some View {
        let expanded = expandedPlans.contains(plan.fileURL.path)
        return Button {
            withAnimation(.snappy(duration: 0.18)) { togglePlan(plan) }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: chevronColumnWidth, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show tasks")
    }

    /// Task rows for an expanded plan: ✓ (all steps checked), ▶ + `← current`
    /// (first task with an unchecked step), else ○ — with per-task counts.
    /// Single-file phased plans (tasks under two or more `## Phase …`
    /// sections) get collapsible phase rows with per-phase rollups; the
    /// phase holding the current task starts open.
    @ViewBuilder
    private func planTasks(_ plan: PlanDoc) -> some View {
        let tasks = renderableTasks(plan)
        if PlanPhases.shouldGroup(tasks) {
            let groups = PlanPhases.groups(tasks)
            let currentGroup = PlanPhases.currentGroupIndex(groups)
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                phaseBlock(group, plan: plan, isCurrentGroup: index == currentGroup)
            }
        } else {
            flatTaskRows(tasks, plan: plan, indent: 28)
        }
    }

    @ViewBuilder
    private func flatTaskRows(_ tasks: [PlanTask], plan: PlanDoc, indent: CGFloat) -> some View {
        let currentIndex = tasks.firstIndex { $0.steps.contains { !$0.checked } }
        ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
            taskRow(task, plan: plan, isCurrent: index == currentIndex, indent: indent)
        }
    }

    @ViewBuilder
    private func phaseBlock(
        _ group: PlanPhases.Group,
        plan: PlanDoc,
        isCurrentGroup: Bool
    ) -> some View {
        // The current phase starts open; a user toggle overrides.
        let key = "\(plan.fileURL.path)#\(group.phase ?? "")"
        let isExpanded = expandedPhaseOverrides[key] ?? isCurrentGroup
        HStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    expandedPhaseOverrides[key] = !isExpanded
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse phase" : "Expand phase")

            // The row itself jumps the plan doc to the phase's `## `
            // heading and TOGGLES the phase — whatever a click opens, a
            // click closes.
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    expandedPhaseOverrides[key] = !isExpanded
                }
                if let line = group.tasks.first?.phaseLine ?? group.tasks.first?.line {
                    onOpenDocAtLine(plan.fileURL, line)
                }
            } label: {
                HStack(spacing: 6) {
                    Text(group.phase ?? "Steps")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1).truncationMode(.tail)
                    if isCurrentGroup {
                        Text("← current")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Text("\(group.checkedSteps)/\(group.totalSteps)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 28)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .contextMenu {
            Button("Course correct…") {
                correcting = CorrectionTarget(
                    plan: plan,
                    anchor: .phase(name: group.phase ?? ""),
                    description: group.phase ?? "Steps")
            }
        }
        if isExpanded {
            flatTaskRows(group.tasks, plan: plan, indent: 46)
        }
    }

    private func taskRow(
        _ task: PlanTask,
        plan: PlanDoc,
        isCurrent: Bool,
        indent: CGFloat
    ) -> some View {
        let checked = task.steps.filter(\.checked).count
        let total = task.steps.count
        let allChecked = checked == total
        let glyph = allChecked ? "checkmark" : (isCurrent ? "arrowtriangle.right.fill" : "circle")
        let tint = isCurrent
            ? AnyShapeStyle(Color.accentColor)
            : AnyShapeStyle(allChecked ? .secondary : .tertiary)
        // Clicking a task opens the plan doc at its heading.
        return Button {
            onOpenDocAtLine(plan.fileURL, task.line)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(task.title.isEmpty ? "Steps" : task.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                if isCurrent {
                    Text("← current")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Text("\(checked)/\(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, indent)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Course correct…") {
                correcting = CorrectionTarget(
                    plan: plan,
                    anchor: .task(line: task.line),
                    description: task.title.isEmpty ? "this task" : task.title)
            }
        }
    }

    /// Tasks worth a row: a heading with at least one checkbox step. A
    /// `### Notes`-style section parses as a zero-step task and is skipped.
    private func renderableTasks(_ plan: PlanDoc) -> [PlanTask] {
        plan.tasks.filter { !$0.steps.isEmpty }
    }

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

    private func togglePlan(_ plan: PlanDoc) {
        let key = plan.fileURL.path
        if expandedPlans.contains(key) { expandedPlans.remove(key) }
        else { expandedPlans.insert(key) }
    }

    // MARK: - Gate anchoring

    /// Whether the queue's gate/attention card belongs under this plan row —
    /// true when the queue is parked and this row is its current plan. A
    /// `.merged` current plan never anchors: an out-of-band merge can leave
    /// the queue parked on a plan that has since merged (e.g. `.attention`
    /// isn't cleared by a tick), and a merged row — in `Done` or as a merged
    /// phase under an active family — would otherwise double up with the
    /// queue-box fallback. The fallback covers that window instead.
    private func shouldAnchorGate(under plan: PlanDoc, status: PlanStatus) -> Bool {
        status != .merged
            && (queue.state == .atGate || queue.state == .attention)
            && queue.currentPlanPath == docStore.relativePath(of: plan)
    }

    /// Whether the queue's current plan is on screen as a row that will
    /// anchor the gate card, so the queue box drops its fallback copy. Kept
    /// the exact complement of `shouldAnchorGate`: a `.merged` current plan
    /// never anchors (even when its row is rendered — a merged phase under an
    /// active family, or a row in `Done`), so the fallback must show. The row
    /// shows when its single-plan initiative is active, or its multi-plan
    /// family is active *and* expanded; anything else falls back.
    private func isGateAnchoredToRenderedRow(_ active: [Initiative], _ statuses: [URL: PlanStatus]) -> Bool {
        guard queue.state == .atGate || queue.state == .attention,
              let current = queue.currentPlanPath,
              let owner = active.first(where: { initiative in
                  initiative.plans.contains { docStore.relativePath(of: $0) == current }
              }),
              let plan = owner.plans.first(where: { docStore.relativePath(of: $0) == current }),
              statuses[plan.fileURL] != .merged
        else { return false }
        guard owner.plans.count > 1 else { return true }
        let memberStatuses = owner.plans.map { statuses[$0.fileURL] ?? .ready }
        return isInitiativeExpanded(owner, memberStatuses)
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
        // The controls are LAYOUT siblings of the row body, not an overlay
        // — the title truncates before ever reaching them, instead of the
        // hover cluster floating over the text.
        HStack(spacing: 4) {
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

            // Hover-revealed trailing controls: the caller's affordance
            // (→ workspace, run controls) stacked with Run for a runnable
            // plan. A live runner keeps them on screen without hover via
            // `keepTrailingVisible`, the same rule the feature rows use.
            if hoveredDocURL == doc.fileURL || keepTrailingVisible {
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
            }
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
