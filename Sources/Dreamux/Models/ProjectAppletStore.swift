import Foundation
import Observation

/// Tracks the per-project App Studio applets under `<project>/apps/` —
/// adopted copies of library applets plus local-born (no-origin) applets.
/// Mirrors `AppLibraryStore`'s scan-is-truth shape, one level down.
@MainActor
@Observable
final class ProjectAppletStore {
    private(set) var applets: [Applet] = []
    /// Folder names under apps/ whose manifest failed to load — the
    /// sidebar renders these as warning rows (spec: degrade visibly,
    /// never crash or silently hide).
    private(set) var invalidFolders: [String] = []
    let appsDir: URL          // <project>/apps
    let stateDir: URL         // <project>/.dreamux

    convenience init(project: Project) {
        self.init(appsDir: project.rootPath.appendingPathComponent("apps", isDirectory: true),
                   stateDir: project.rootPath.appendingPathComponent(".dreamux", isDirectory: true))
    }

    /// Test seam: same shape, explicit roots.
    init(appsDir: URL, stateDir: URL) {
        self.appsDir = appsDir
        self.stateDir = stateDir
        refresh()
    }

    func applet(id: UUID) -> Applet? {
        applets.first { $0.id == id }
    }

    /// Reconcile the in-memory list with `appsDir`'s contents: every
    /// subdirectory with a loadable manifest becomes an `Applet` (sorted
    /// by name); the rest are recorded in `invalidFolders` — never crash.
    func refresh() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: appsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var discovered: [Applet] = []
        var invalid: [String] = []
        for url in contents {
            let standardized = url.standardizedFileURL
            let resources = try? standardized.resourceValues(forKeys: [.isDirectoryKey])
            guard resources?.isDirectory == true else { continue }
            if let manifest = AppletManifest.load(from: standardized) {
                discovered.append(Applet(manifest: manifest, folderURL: standardized))
            } else {
                invalid.append(standardized.lastPathComponent)
            }
        }

        discovered.sort { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
        invalid.sort()
        applets = discovered
        invalidFolders = invalid
    }

    /// Copy a library applet into this project. The copy gets a NEW id, a
    /// slug uniqued against this project, and `origin` stamped with the
    /// library applet's id + content hash (hashed from the source library
    /// folder, pre-copy) + now.
    ///
    /// The slug is uniqued against live disk state (this store's `refresh()`
    /// plus on-disk folder names under `appsDir`), not just the in-memory
    /// cache, so a stale cache or a manifest-less squatter folder can never
    /// be silently clobbered.
    @discardableResult
    func adopt(_ library: Applet) throws -> Applet {
        let sourceHash = AppletContentHash.hash(of: library.folderURL)
        let slug = try uniqueSlug(for: library.manifest.name)
        let destination = appsDir.appendingPathComponent(slug, isDirectory: true)

        let fm = FileManager.default
        try fm.createDirectory(at: appsDir, withIntermediateDirectories: true)
        try fm.copyItem(at: library.folderURL, to: destination)

        var manifest = library.manifest
        manifest.id = UUID()
        manifest.slug = slug
        manifest.origin = AppletManifest.Origin(id: library.id, hash: sourceHash, adoptedAt: Date())
        try manifest.write(to: destination)

        refresh()
        return Applet(manifest: manifest, folderURL: destination)
    }

    /// Scaffold a local-born applet (no origin).
    @discardableResult
    func createLocal(name: String, description: String, icon: String) throws -> Applet {
        let slug = try uniqueSlug(for: name)
        let manifest = AppletManifest(
            id: UUID(),
            name: name,
            slug: slug,
            icon: icon,
            description: description,
            requiresCapabilities: [],
            origin: nil
        )
        let folderURL = appsDir.appendingPathComponent(slug, isDirectory: true)
        try AppletScaffold.write(to: folderURL, manifest: manifest)
        refresh()
        return Applet(manifest: manifest, folderURL: folderURL)
    }

    /// Delete the applet folder AND its data dir. Not trash — the confirm
    /// dialog (Task 8) is the safety net, and appdata under .dreamux is
    /// runtime state.
    func remove(_ applet: Applet) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: applet.folderURL.path) {
            try fm.removeItem(at: applet.folderURL)
        }
        let data = dataDir(for: applet)
        if fm.fileExists(atPath: data.path) {
            try fm.removeItem(at: data)
        }
        refresh()
    }

    /// Copy a local-born applet up to the library (new library id, slug
    /// uniqued there, origin nil on the library copy), then stamp THIS
    /// project copy's manifest.origin to point at the new library applet
    /// (+ hash of the just-published library folder).
    @discardableResult
    func publish(_ applet: Applet, to library: AppLibraryStore) throws -> Applet {
        library.refresh()
        let onDiskNames = (try? FileManager.default.contentsOfDirectory(atPath: library.root.path)) ?? []
        let taken = Set(library.applets.map(\.slug)).union(onDiskNames)
        let slug = AppletSlug.unique(AppletSlug.slugify(applet.manifest.name), existing: taken)
        let destination = library.root.appendingPathComponent(slug, isDirectory: true)

        let fm = FileManager.default
        try fm.createDirectory(at: library.root, withIntermediateDirectories: true)
        try fm.copyItem(at: applet.folderURL, to: destination)

        var libraryManifest = applet.manifest
        libraryManifest.id = UUID()
        libraryManifest.slug = slug
        libraryManifest.origin = nil
        try libraryManifest.write(to: destination)
        library.refresh()

        let publishedHash = AppletContentHash.hash(of: destination)
        var localManifest = applet.manifest
        localManifest.origin = AppletManifest.Origin(id: libraryManifest.id, hash: publishedHash, adoptedAt: Date())
        try localManifest.write(to: applet.folderURL)
        refresh()

        return Applet(manifest: libraryManifest, folderURL: destination)
    }

    /// <project>/.dreamux/appdata/<slug>/ — created on demand (via
    /// DreamuxStateDir.ensure so .dreamux stays gitignored).
    func dataDir(for applet: Applet) -> URL {
        let dir = stateDir.appendingPathComponent("appdata", isDirectory: true)
            .appendingPathComponent(applet.slug, isDirectory: true)
        DreamuxStateDir.ensure(containing: dir.appendingPathComponent(".keep"))
        return dir
    }

    /// Unique a candidate slug against this store's live disk state: a
    /// fresh `refresh()` plus the on-disk folder names under `appsDir`
    /// (which catches manifest-less squatters and out-of-band writers a
    /// stale in-memory cache would miss).
    private func uniqueSlug(for name: String) throws -> String {
        refresh()
        let fm = FileManager.default
        try fm.createDirectory(at: appsDir, withIntermediateDirectories: true)
        let onDiskNames = (try? fm.contentsOfDirectory(atPath: appsDir.path)) ?? []
        let taken = Set(applets.map(\.slug)).union(onDiskNames)
        return AppletSlug.unique(AppletSlug.slugify(name), existing: taken)
    }
}
