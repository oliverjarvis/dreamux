import SwiftUI
import UniformTypeIdentifiers

/// Collapsible "Plans & Specs" sidebar section (rendered above the
/// Features list). Plans carry derived status + checkbox progress;
/// unpaired specs surface as "needs plan"; everything else sits behind
/// a Docs disclosure. Rows open in the workspace's editor tabs.
struct PlansSpecsSection: View {
    @Bindable var docStore: DocStore
    @Bindable var layout: SidebarLayoutStore
    let featureExists: (String) -> Bool
    let onOpenDoc: (URL) -> Void
    let onRunPlan: (PlanDoc) -> Void
    let onNewPlan: () -> Void
    let onWritePlan: (PlanDoc) -> Void
    @Bindable var queue: PlanQueueController
    let onOpenFeature: (String) -> Void   // feature name → activate workspace
    let onEnqueue: (PlanDoc) -> Void

    @State private var doneExpanded = false
    @State private var docsExpanded = false
    @State private var hoveredDocURL: URL?
    @State private var hoveredChipURL: URL?
    /// Plan rows expanded to their task list, keyed by plan file path.
    /// Deliberately not persisted — a per-session affordance.
    @State private var expandedPlans: Set<String> = []
    /// Queue row currently being dragged for reorder — see `queueSection`.
    @State private var draggingQueueItem: QueueItem?

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
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { layout.plansExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(layout.plansExpanded ? 90 : 0))
                    Text("Plans & Specs")
                        .font(.system(size: 11, weight: .semibold))
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
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rescan docs")

            Button(action: onNewPlan) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
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
        // Every merged plan folds into the shared Done disclosure — a
        // merged single-plan initiative and a merged phase land together.
        let done = docStore.plans.filter { statuses[$0.fileURL] == .merged }

        VStack(spacing: 2) {
            queueSection
            ForEach(active) { initiative in
                initiativeRows(initiative, statuses: statuses)
            }
            ForEach(needsPlan) { initiative in
                if let spec = initiative.spec { specOnlyRow(spec) }
            }
            if !done.isEmpty {
                disclosure("Done (\(done.count))", isExpanded: $doneExpanded) {
                    ForEach(done) { plan in
                        planBlock(plan, status: .merged, ordinal: nil, chips: [])
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

    /// Non-merged plans of an initiative, rendered as consecutive rows. The
    /// spec/supporting-doc chip line attaches under the first plan row; a
    /// multi-plan family also prefixes each row with its 1-based ordinal
    /// (grouping-row treatment is a later task).
    @ViewBuilder
    private func initiativeRows(_ initiative: Initiative, statuses: [URL: PlanStatus]) -> some View {
        let plans = initiative.plans.filter { statuses[$0.fileURL] != .merged }
        let multi = initiative.plans.count > 1
        let chips = docChips(for: initiative)
        ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
            planBlock(
                plan,
                status: statuses[plan.fileURL] ?? .ready,
                ordinal: multi ? ordinal(of: plan, in: initiative) : nil,
                chips: index == 0 ? chips : [])
        }
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
    private var queueSection: some View {
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

                gateCardIfAny
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
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(path == queue.currentPlanPath && queue.state != .idle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var gateCardIfAny: some View {
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
    /// (first plan of an initiative) and, when expanded, its task rows.
    @ViewBuilder
    private func planBlock(_ plan: PlanDoc, status: PlanStatus, ordinal: Int?, chips: [Chip]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            planRow(plan, status: status, ordinal: ordinal)
            if !chips.isEmpty { chipLine(chips) }
            if expandedPlans.contains(plan.fileURL.path) { planTasks(plan) }
        }
    }

    private func planRow(_ plan: PlanDoc, status: PlanStatus, ordinal: Int?) -> some View {
        // The disclosure chevron overlays the row's leading gap rather than
        // nesting inside its open-doc button — the same on-top idiom the
        // feature rows use for their hover controls, so a click on the
        // chevron toggles tasks without opening the doc.
        ZStack(alignment: .leading) {
            docRow(plan, canRun: status == .ready || status == .inProgress) {
                HStack(spacing: 8) {
                    Color.clear.frame(width: chevronColumnWidth, height: 18)
                    Image(systemName: status.glyph)
                        .font(.system(size: 12, weight: .semibold))
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
                .font(.system(size: 8, weight: .semibold))
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
    @ViewBuilder
    private func planTasks(_ plan: PlanDoc) -> some View {
        let tasks = renderableTasks(plan)
        let currentIndex = tasks.firstIndex { $0.steps.contains { !$0.checked } }
        ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
            taskRow(task, isCurrent: index == currentIndex)
        }
    }

    private func taskRow(_ task: PlanTask, isCurrent: Bool) -> some View {
        let checked = task.steps.filter(\.checked).count
        let total = task.steps.count
        let allChecked = checked == total
        let glyph = allChecked ? "checkmark" : (isCurrent ? "arrowtriangle.right.fill" : "circle")
        let tint = isCurrent
            ? AnyShapeStyle(Color.accentColor)
            : AnyShapeStyle(allChecked ? .secondary : .tertiary)
        return HStack(spacing: 8) {
            Image(systemName: glyph)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(task.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            if isCurrent {
                Text("← current")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Text("\(checked)/\(total)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 28)
        .padding(.trailing, 12)
        .padding(.vertical, 2)
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
        for doc in initiative.supportingDocs {
            chips.append(Chip(label: DocChipLabel.label(title: doc.title, isSpec: false),
                              url: doc.fileURL))
        }
        return chips
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

    private func ordinal(of plan: PlanDoc, in initiative: Initiative) -> Int? {
        initiative.plans.firstIndex { $0.id == plan.id }.map { $0 + 1 }
    }

    private func specOnlyRow(_ spec: PlanDoc) -> some View {
        docRow(spec, canRun: false) {
            HStack(spacing: 8) {
                Image(systemName: PlanStatus.specOnly.glyph)
                    .font(.system(size: 12, weight: .semibold))
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
    private func docRow<Body: View>(
        _ doc: PlanDoc,
        canRun: Bool,
        @ViewBuilder body: () -> Body
    ) -> some View {
        ZStack(alignment: .trailing) {
            Button { onOpenDoc(doc.fileURL) } label: {
                body()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                if hoveredDocURL == doc.fileURL {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .padding(.horizontal, 4)
                }
            }
            .contextMenu {
                if canRun {
                    Button("Run Plan…") { onRunPlan(doc) }
                    Button("Add to Queue") { onEnqueue(doc) }
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([doc.fileURL])
                }
            }

            if canRun, hoveredDocURL == doc.fileURL {
                Button { onRunPlan(doc) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
                .help("Run this plan (provisions a worktree and starts claude)")
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
                        .font(.system(size: 8, weight: .semibold))
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
