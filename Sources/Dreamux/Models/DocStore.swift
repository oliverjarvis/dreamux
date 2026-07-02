import Foundation
import Observation

/// Discovers and watches the project-level docs home (`<project>/docs/`),
/// classifying every markdown file by shape via `PlanDoc`. Holds the run
/// ledger so views can derive each plan's status in one place. Watching
/// is kqueue-based (one DispatchSource per directory, rebuilt on every
/// scan) — the docs tree is shallow, and live checkbox ticks from a
/// running claude session land as `.write` events on `docs/plans/`.
@MainActor
@Observable
final class DocStore {
    private(set) var docs: [PlanDoc] = []
    let docsRoot: URL
    let projectRoot: URL
    let ledger: PlanRunLedger

    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var debounce: Task<Void, Never>?

    init(project: Project) {
        projectRoot = project.rootPath
        docsRoot = project.rootPath.appendingPathComponent("docs", isDirectory: true)
        ledger = PlanRunLedger(project: project)
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
                }
            }
        }

        // Pairing pass: a file referenced by any plan's **Spec:** line is
        // a spec even without the -design suffix.
        let referencedSpecs = Set(found
            .filter { $0.kind == .plan }
            .compactMap { $0.specReference.map { ref in resolve(ref) } })
        docs = found.map { doc in
            if doc.kind == .doc, referencedSpecs.contains(canonical(doc.fileURL)) {
                return PlanDoc(
                    fileURL: doc.fileURL, kind: .spec, title: doc.title, date: doc.date,
                    goal: doc.goal, specReference: doc.specReference,
                    checkedSteps: doc.checkedSteps, totalSteps: doc.totalSteps)
            }
            return doc
        }
        .sorted { ($0.date ?? "") > ($1.date ?? "") }

        rebuildWatchers(for: directories)
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
        if let ref = plan.specReference {
            let target = resolve(ref)
            if let match = docs.first(where: { canonical($0.fileURL) == target }) {
                return match
            }
        }
        let expected = PlanDoc.branchName(forFileName: plan.fileURL.lastPathComponent)
        return docs.first {
            $0.kind == .spec
                && PlanDoc.branchName(forFileName: $0.fileURL.lastPathComponent) == expected
        }
    }

    func relativePath(of doc: PlanDoc) -> String {
        canonical(doc.fileURL).path.replacingOccurrences(
            of: canonical(projectRoot).path + "/", with: "")
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

    // MARK: - Watching

    func startWatching() { refresh() }

    func stopWatching() {
        watchers.forEach { $0.cancel() }
        watchers = []
        debounce?.cancel()
    }

    private func rebuildWatchers(for directories: [URL]) {
        watchers.forEach { $0.cancel() }
        watchers = directories.compactMap { dir in
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
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
        let raw = reference.hasPrefix("/")
            ? URL(fileURLWithPath: reference)
            : projectRoot.appendingPathComponent(reference)
        return canonical(raw)
    }

    /// `URL.standardizedFileURL` doesn't resolve macOS's `/var` →
    /// `/private/var`-style symlinks, but `FileManager`'s recursive
    /// enumerator does for any file reached by descending into a
    /// subdirectory — so a URL built by hand (`projectRoot.appending(...)`)
    /// can silently diverge from the same file's `doc.fileURL` two levels
    /// down (exactly the shape of `docs/plans/*.md`). Route every path
    /// comparison through `realpath(3)` so both sides land on the same
    /// canonical string; fall back to `standardizedFileURL` when the path
    /// doesn't exist yet (nothing on disk to resolve against).
    private func canonical(_ url: URL) -> URL {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return url.standardizedFileURL }
        return URL(fileURLWithPath: String(cString: buffer))
    }
}
