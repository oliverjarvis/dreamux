import Foundation
import Observation

/// Discovers and watches the project-level docs home (`<project>/docs/`),
/// classifying every markdown file by shape via `PlanDoc`. Holds the run
/// ledger so views can derive each plan's status in one place. Watching
/// is kqueue-based (one DispatchSource per watched path, rebuilt on every
/// scan) — the docs tree is shallow. Watchers cover both each directory
/// (entry changes: create/rename/delete) and each doc file (in-place
/// content writes, how claude's Edit tool updates a checklist), since a
/// directory kqueue source alone fires on neither.
@MainActor
@Observable
final class DocStore {
    private(set) var docs: [PlanDoc] = []
    /// Work grouped into initiatives (spec + ordered plans + supporting
    /// docs). Re-derived from `docs` on every scan; see `regroup`.
    private(set) var initiatives: [Initiative] = []
    /// `.doc`-kind files that pair with no initiative — hidden when empty.
    private(set) var looseDocs: [PlanDoc] = []
    let docsRoot: URL
    let projectRoot: URL
    let ledger: PlanRunLedger

    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var debounce: Task<Void, Never>?

    /// Fired at the end of every `refresh()`, once `docs`/`initiatives` and
    /// the watchers reflect the fresh scan. `ProjectSession` sets this to run
    /// intake enactment (auto-enqueue `**Runs:** after` plans) against the
    /// new inventory. Default no-op so DocStore stands alone in tests/previews.
    @ObservationIgnored var onRefresh: () -> Void = {}

    init(project: Project) {
        projectRoot = project.rootPath
        docsRoot = project.rootPath.appendingPathComponent("docs", isDirectory: true)
        ledger = PlanRunLedger(project: project)
    }

    deinit {
        watchers.forEach { $0.cancel() }
        debounce?.cancel()
    }

    static func ensureDocsHome(at projectRoot: URL) {
        let docs = projectRoot.appendingPathComponent("docs", isDirectory: true)
        for sub in ["specs", "plans"] {
            try? FileManager.default.createDirectory(
                at: docs.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true)
        }
    }

    // MARK: - Scan

    func refresh() {
        var found: [PlanDoc] = []
        // Raw bodies (keyed by standardized URL) so supporting-doc
        // absorption can substring-match member filenames without
        // re-reading files or bloating every `PlanDoc`.
        var bodies: [URL: String] = [:]
        var directories: [URL] = [docsRoot]
        let fm = FileManager.default
        if let enumerator = fm.enumerator(
            at: docsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    directories.append(url)
                } else if url.pathExtension.lowercased() == "md",
                          let contents = try? String(contentsOf: url, encoding: .utf8) {
                    found.append(PlanDoc.parse(fileURL: url, contents: contents))
                    bodies[url.standardizedFileURL] = contents
                }
            }
        }

        // Pairing pass: a file referenced by any plan's **Spec:** line is
        // a spec even without the -design suffix.
        let referencedSpecs = Set(found
            .filter { $0.kind == .plan }
            .compactMap { $0.specReference.map { ref in resolve(ref).standardizedFileURL } })
        docs = found.map { doc in
            if doc.kind == .doc, referencedSpecs.contains(doc.fileURL.standardizedFileURL) {
                return PlanDoc(
                    fileURL: doc.fileURL, kind: .spec, title: doc.title, date: doc.date,
                    goal: doc.goal, specReference: doc.specReference, runsAfter: doc.runsAfter,
                    declaresParallel: doc.declaresParallel,
                    checkedSteps: doc.checkedSteps, totalSteps: doc.totalSteps, tasks: doc.tasks)
            }
            return doc
        }
        .sorted { ($0.date ?? "") > ($1.date ?? "") }

        regroup(bodies: bodies)
        rebuildWatchers(for: directories + docs.map(\.fileURL))
        onRefresh()
    }

    // MARK: - Views over the scan

    var plans: [PlanDoc] { docs.filter { $0.kind == .plan } }

    var unpairedSpecs: [PlanDoc] {
        let paired = Set(plans.compactMap { pairedSpec(for: $0)?.fileURL })
        return docs.filter { $0.kind == .spec && !paired.contains($0.fileURL) }
    }

    var otherDocs: [PlanDoc] { docs.filter { $0.kind == .doc } }

    /// The plan's spec: **Spec:** back-link first (authoritative), then
    /// the filename convention (plan name + `-design`).
    func pairedSpec(for plan: PlanDoc) -> PlanDoc? {
        if let ref = plan.specReference, let match = doc(matchingReference: ref) {
            return match
        }
        let expected = PlanDoc.branchName(forFileName: plan.fileURL.lastPathComponent)
        return docs.first {
            $0.kind == .spec
                && PlanDoc.branchName(forFileName: $0.fileURL.lastPathComponent) == expected
        }
    }

    /// The doc whose file URL matches `reference` (resolved against the
    /// project root). Shared path-matching for the **Spec:** back-link,
    /// used by both `pairedSpec(for:)` and initiative grouping.
    private func doc(matchingReference reference: String) -> PlanDoc? {
        let target = resolve(reference).standardizedFileURL
        return docs.first { $0.fileURL.standardizedFileURL == target }
    }

    func relativePath(of doc: PlanDoc) -> String {
        doc.fileURL.standardizedFileURL.path.replacingOccurrences(
            of: projectRoot.standardizedFileURL.path + "/", with: "")
    }

    /// Resolve a header reference (a `**Runs:**`/`**Spec:**` path) to an
    /// absolute, standardized URL — the same `resolve` + `standardizedFileURL`
    /// discipline `doc(matchingReference:)` uses for the **Spec:** back-link.
    /// Exposed so intake enactment matches a blocker path symmetrically: a
    /// `./docs/…` or otherwise non-canonical form resolves to the same doc.
    func resolvedURL(forReference reference: String) -> URL {
        resolve(reference).standardizedFileURL
    }

    func status(for doc: PlanDoc, featureExists: (String) -> Bool) -> PlanStatus {
        guard doc.kind == .plan else { return .specOnly }
        let record = ledger.recordForPlan(relativePath(of: doc))
        return PlanStatusResolver.status(
            checked: doc.checkedSteps,
            total: doc.totalSteps,
            hasRun: record != nil,
            featureExists: record.map { featureExists($0.featureName) } ?? false
        )
    }

    /// Prune ledger records for features closed before completing their
    /// plan. Call whenever the feature list changes.
    func reconcileLedger(existingFeatureNames: Set<String>) {
        ledger.reconcile(existingFeatureNames: existingFeatureNames) { planPath in
            guard let doc = docs.first(where: { relativePath(of: $0) == planPath })
            else { return false }
            return doc.totalSteps > 0 && doc.checkedSteps == doc.totalSteps
        }
    }

    // MARK: - Grouping

    /// Rebuild `initiatives`/`looseDocs` from `docs`. Signals, applied in
    /// order (see the design doc): (1) a plan's **Spec:** back-link and any
    /// `.doc` whose body links to a member; (2) slug family union; (3)
    /// plan order by explicit `Phase N`, else (date, filename).
    private func regroup(bodies: [URL: String]) {
        // Union-find over the plan/spec docs; slug family and back-links
        // both merge members of one family into a single component.
        let core = docs.filter { $0.kind == .plan || $0.kind == .spec }
        var parent = Array(0..<core.count)
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        var indexByURL: [URL: Int] = [:]
        for (i, d) in core.enumerated() { indexByURL[d.fileURL.standardizedFileURL] = i }

        var firstOfFamily: [String: Int] = [:]
        for (i, d) in core.enumerated() {
            let key = PlanDoc.familyKey(forFileName: d.fileURL.lastPathComponent)
            if let j = firstOfFamily[key] { union(i, j) } else { firstOfFamily[key] = i }
        }
        for (i, d) in core.enumerated() where d.kind == .plan {
            if let spec = pairedSpec(for: d),
               let j = indexByURL[spec.fileURL.standardizedFileURL] {
                union(i, j)
            }
        }

        var membersByRoot: [Int: [PlanDoc]] = [:]
        for (i, d) in core.enumerated() { membersByRoot[find(i), default: []].append(d) }

        // Order components deterministically (earliest member first) so
        // the "first family that references it" absorption below is stable.
        var supporting = membersByRoot.values.map { (members: $0, docs: [PlanDoc]()) }
        supporting.sort { Self.membersSortBefore($0.members, $1.members) }

        var loose: [PlanDoc] = []
        for d in docs where d.kind == .doc {
            let body = bodies[d.fileURL.standardizedFileURL] ?? ""
            if let gi = supporting.firstIndex(where: { group in
                group.members.contains { referencesMember($0, in: body) }
            }) {
                supporting[gi].docs.append(d)
            } else {
                loose.append(d)
            }
        }

        var built = supporting.map { group in
            Self.makeInitiative(members: group.members,
                                supportingDocs: group.docs,
                                primarySpec: { plans, specs in
                                    self.primarySpec(for: plans, among: specs)
                                })
        }
        // Newest initiative first (matching the docs list), keyed by the
        // earliest date among an initiative's members so a late-added
        // supporting doc can't hoist it; filename breaks ties.
        built.sort { a, b in
            let da = Self.representativeDate(a), db = Self.representativeDate(b)
            if da != db { return da > db }
            return Self.representativeName(a) < Self.representativeName(b)
        }
        initiatives = built
        looseDocs = loose.sorted(by: Self.docSortsBefore)
    }

    /// A `.doc` joins a family when its body names a member by full
    /// filename (with extension) or project-relative path — the full
    /// filename keeps a shared common word from pulling in a stray doc.
    private func referencesMember(_ member: PlanDoc, in body: String) -> Bool {
        body.contains(member.fileURL.lastPathComponent) || body.contains(relativePath(of: member))
    }

    /// The family's design doc: the spec a plan back-links to, else the
    /// earliest spec. Extra specs fall through to `supportingDocs`.
    private func primarySpec(for plans: [PlanDoc], among specs: [PlanDoc]) -> PlanDoc? {
        for plan in plans {
            if let spec = pairedSpec(for: plan),
               specs.contains(where: { $0.fileURL == spec.fileURL }) {
                return spec
            }
        }
        return specs.first
    }

    private static func makeInitiative(
        members: [PlanDoc], supportingDocs: [PlanDoc],
        primarySpec: (_ plans: [PlanDoc], _ specs: [PlanDoc]) -> PlanDoc?
    ) -> Initiative {
        let plans = orderedPlans(members.filter { $0.kind == .plan })
        let specs = members.filter { $0.kind == .spec }.sorted(by: docSortsBefore)
        let primary = primarySpec(plans, specs)
        let extraSpecs = specs.filter { $0.fileURL != primary?.fileURL }
        let key = familyKey(of: plans.first ?? primary ?? members[0])
        return Initiative(
            id: key,
            title: initiativeTitle(spec: primary, plans: plans, familyKey: key),
            spec: primary,
            plans: plans,
            supportingDocs: extraSpecs + supportingDocs.sorted(by: docSortsBefore))
    }

    /// Plans in execution order: explicit `Phase N` (title, else filename)
    /// wins over date; unphased plans sort after by (date, filename).
    private static func orderedPlans(_ plans: [PlanDoc]) -> [PlanDoc] {
        plans.sorted { a, b in
            let pa = explicitPhase(of: a) ?? .max, pb = explicitPhase(of: b) ?? .max
            if pa != pb { return pa < pb }
            return (a.date ?? "", a.fileURL.lastPathComponent)
                < (b.date ?? "", b.fileURL.lastPathComponent)
        }
    }

    private static func explicitPhase(of plan: PlanDoc) -> Int? {
        if let n = firstCapturedInt(#"(?i)\b(?:phase|part)\s+(\d+)"#, in: plan.title) { return n }
        let stem = plan.fileURL.deletingPathExtension().lastPathComponent
        return firstCapturedInt(#"(?i)(?:phase|part)-(\d+)"#, in: stem)
    }

    private static func initiativeTitle(spec: PlanDoc?, plans: [PlanDoc], familyKey: String) -> String {
        if let spec { return stripTrailingDecoration(spec.title) }
        if let prefix = commonPlanTitlePrefix(plans) { return prefix }
        return humanize(familyKey)
    }

    /// `Design — trailing prose` → `Design`.
    private static func stripTrailingDecoration(_ title: String) -> String {
        guard let dash = title.range(of: " — ") else { return title }
        return String(title[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// Longest common prefix of the plan titles (boilerplate suffix
    /// stripped), cut to a whole word and required to be ≥ 4 chars.
    private static func commonPlanTitlePrefix(_ plans: [PlanDoc]) -> String? {
        let titles = plans.map(strippedPlanTitle).filter { !$0.isEmpty }
        guard let first = titles.first else { return nil }
        var prefix = Array(first)
        for title in titles.dropFirst() {
            let chars = Array(title)
            var k = 0
            while k < prefix.count, k < chars.count, prefix[k] == chars[k] { k += 1 }
            prefix.removeSubrange(k...)
        }
        var result = String(prefix).trimmingCharacters(in: .whitespaces)
        // Trim a partial trailing word only when the run breaks mid-word —
        // a word char on both sides of the divergence. A break at a space
        // is already a clean boundary, so the whole trailing word stays.
        if titles.count > 1, prefix.count > 0, prefix.count < first.count {
            let chars = Array(first)
            let brokeMidWord = !chars[prefix.count - 1].isWhitespace
                && !chars[prefix.count].isWhitespace
            if brokeMidWord, let lastSpace = result.lastIndex(of: " ") {
                result = String(result[..<lastSpace]).trimmingCharacters(in: .whitespaces)
            }
        }
        return result.count >= 4 ? result : nil
    }

    private static func strippedPlanTitle(_ plan: PlanDoc) -> String {
        let suffix = " Implementation Plan"
        var title = plan.title
        if title.hasSuffix(suffix) { title = String(title.dropLast(suffix.count)) }
        return title.trimmingCharacters(in: .whitespaces)
    }

    private static func humanize(_ slug: String) -> String {
        slug.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func familyKey(of doc: PlanDoc) -> String {
        PlanDoc.familyKey(forFileName: doc.fileURL.lastPathComponent)
    }

    // Sort keys: (date, filename) ascending for docs; the earliest of
    // those across an initiative's members represents the initiative.

    private static func docSortsBefore(_ a: PlanDoc, _ b: PlanDoc) -> Bool {
        (a.date ?? "", a.fileURL.lastPathComponent)
            < (b.date ?? "", b.fileURL.lastPathComponent)
    }

    private static func membersSortBefore(_ a: [PlanDoc], _ b: [PlanDoc]) -> Bool {
        (minDate(a), minName(a)) < (minDate(b), minName(b))
    }

    // Members = spec + plans (not supporting docs), so the initiative sort
    // key shares one date basis with the component ordering above: an
    // early-dated roadmap can't drag its initiative back up the list.
    private static func members(_ i: Initiative) -> [PlanDoc] {
        i.plans + [i.spec].compactMap { $0 }
    }
    private static func representativeDate(_ i: Initiative) -> String { minDate(members(i)) }
    private static func representativeName(_ i: Initiative) -> String { minName(members(i)) }
    private static func minDate(_ docs: [PlanDoc]) -> String { docs.compactMap { $0.date }.min() ?? "" }
    private static func minName(_ docs: [PlanDoc]) -> String {
        docs.map { $0.fileURL.lastPathComponent }.min() ?? ""
    }

    private static func firstCapturedInt(_ pattern: String, in text: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    // MARK: - Watching

    func startWatching() { refresh() }

    func stopWatching() {
        watchers.forEach { $0.cancel() }
        watchers = []
        debounce?.cancel()
    }

    private func rebuildWatchers(for paths: [URL]) {
        watchers.forEach { $0.cancel() }
        watchers = paths.compactMap { path in
            let fd = open(path.path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename, .delete],
                queue: .main)
            source.setEventHandler { [weak self] in self?.scheduleRefresh() }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func resolve(_ reference: String) -> URL {
        reference.hasPrefix("/")
            ? URL(fileURLWithPath: reference)
            : projectRoot.appendingPathComponent(reference)
    }
}
