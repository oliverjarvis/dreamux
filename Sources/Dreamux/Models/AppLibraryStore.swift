import Foundation
import Observation

/// Tracks the global App Studio applet library — the reusable applets a
/// user builds once and can adopt into any project. Applets live under
/// `~/Documents/Dreamux/Apps/` by default, a reserved subdirectory of
/// `ProjectStore.projectsRootURL()` (see `ProjectStore.isReservedProjectFolderName`
/// for why it never surfaces as a project itself).
///
/// `$DREAMUX_APPS_ROOT` overrides the root purely for the e2e test harness,
/// mirroring `DREAMUX_PROJECTS_ROOT` in `ProjectStore`.
@MainActor
@Observable
final class AppLibraryStore {
    private(set) var applets: [Applet] = []
    let root: URL

    /// `$DREAMUX_APPS_ROOT` when set (e2e/tests), else
    /// `ProjectStore.projectsRootURL()/Apps`. Created on demand.
    nonisolated static func appsRootURL() -> URL {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let root: URL
        if let override = env["DREAMUX_APPS_ROOT"], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = ProjectStore.projectsRootURL().appendingPathComponent("Apps", isDirectory: true)
        }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    init(root: URL = AppLibraryStore.appsRootURL()) {
        self.root = root
        refresh()
    }

    func applet(id: UUID) -> Applet? {
        applets.first { $0.id == id }
    }

    /// Reconcile the in-memory applet list with the contents of `root`.
    /// The folder is the source of truth: every subdirectory with a
    /// loadable manifest becomes an `Applet` (sorted by name); invalid
    /// ones are skipped — never crash.
    func refresh() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var discovered: [Applet] = []
        for url in contents {
            let standardized = url.standardizedFileURL
            let resources = try? standardized.resourceValues(forKeys: [.isDirectoryKey])
            guard resources?.isDirectory == true else { continue }
            guard let manifest = AppletManifest.load(from: standardized) else { continue }
            discovered.append(Applet(manifest: manifest, folderURL: standardized))
        }

        discovered.sort { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
        applets = discovered
    }

    /// Scaffold a new canonical applet (slug uniqued against current
    /// library slugs), refresh, return it.
    ///
    /// The slug is uniqued against *live disk state*, not just the
    /// in-memory cache: another store instance over the same root (App
    /// Studio window vs. main window) may have created a folder since our
    /// last refresh, and `AppletScaffold.write` would silently clobber it.
    /// On-disk subdirectory names count even without a loadable manifest,
    /// so a broken folder is never overwritten either.
    @discardableResult
    func createApplet(name: String, description: String, icon: String) throws -> Applet {
        refresh()
        let onDiskNames = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let taken = Set(applets.map(\.slug)).union(onDiskNames)
        let slug = AppletSlug.unique(AppletSlug.slugify(name), existing: taken)
        let manifest = AppletManifest(
            id: UUID(),
            name: name,
            slug: slug,
            icon: icon,
            description: description,
            requiresCapabilities: [],
            origin: nil
        )
        let folderURL = root.appendingPathComponent(slug, isDirectory: true)
        try AppletScaffold.write(to: folderURL, manifest: manifest)
        refresh()
        return Applet(manifest: manifest, folderURL: folderURL)
    }

    /// Trash the applet folder (recoverable), refresh.
    func delete(_ applet: Applet) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: applet.folderURL.path) {
            var trashedURL: NSURL?
            try fm.trashItem(at: applet.folderURL, resultingItemURL: &trashedURL)
        }
        refresh()
    }
}
