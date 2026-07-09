import Foundation
import Observation

enum ProjectError: LocalizedError {
    case invalidName
    case alreadyExists(name: String)
    case createDirectoryFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Please enter a project name."
        case .alreadyExists(let name):
            return "A project named “\(name)” already exists."
        case .createDirectoryFailed(let underlying):
            return "Couldn't create the project folder: \(underlying.localizedDescription)"
        }
    }
}

/// Tracks the user's projects and where they live on disk. The list is
/// persisted as JSON under Application Support; project directories
/// themselves live under ~/Documents/Dreamux by default so the user
/// can browse them in Finder.
///
/// Two environment variables exist purely for the e2e test harness, so
/// a sandboxed app launch never touches the user's real Documents or
/// Application Support:
///
/// - `DREAMUX_PROJECTS_ROOT` replaces `~/Documents/Dreamux` as the
///   directory projects are discovered in and created under.
/// - `DREAMUX_STATE_DIR` replaces `~/Library/Application Support/
///   Dreamux` as the home of `projects.json`.
///
/// Both are honored only when set to a non-empty value, and the
/// directories are created on demand. When unset, behavior is identical
/// to a normal user launch.
@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []

    let projectsRoot: URL
    private let storeURL: URL

    init() {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment

        let appDir: URL
        if let override = env["DREAMUX_STATE_DIR"], !override.isEmpty {
            appDir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let appSupport = (try? fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
            appDir = appSupport.appendingPathComponent("Dreamux", isDirectory: true)
        }
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.storeURL = appDir.appendingPathComponent("projects.json")

        self.projectsRoot = Self.projectsRootURL()

        load()
        refresh()
    }

    /// The directory every project folder lives under — `~/Documents/Dreamux`
    /// by default, or `$DREAMUX_PROJECTS_ROOT`. Created if absent. Nonisolated
    /// and static so the `dreamux` CLI resolves the exact same root the app
    /// scans, without needing a main-actor `ProjectStore`.
    nonisolated static func projectsRootURL() -> URL {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let root: URL
        if let override = env["DREAMUX_PROJECTS_ROOT"], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let documents = (try? fm.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents")
            root = documents.appendingPathComponent("Dreamux", isDirectory: true)
        }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Folder names under `projectsRoot` that are NOT projects — currently
    /// just "Apps", the App Studio applet library (`AppLibraryStore`).
    /// Pure so it's testable without env plumbing.
    nonisolated static func isReservedProjectFolderName(_ name: String) -> Bool {
        name == "Apps"
    }

    func project(id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    /// Create a new project folder under `projectsRoot` and return a
    /// `Project` for it. The folder is the source of truth — `refresh()`
    /// would discover it on next scan even without this call, but doing
    /// it explicitly lets us hand back a `Project` for the caller to
    /// open in a window immediately.
    @discardableResult
    func createProject(name: String) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectError.invalidName }

        let safeName = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = projectsRoot.appendingPathComponent(safeName, isDirectory: true)
        let fm = FileManager.default

        if fm.fileExists(atPath: url.path) {
            throw ProjectError.alreadyExists(name: safeName)
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ProjectError.createDirectoryFailed(underlying: error)
        }

        let project = Project(name: safeName, rootPath: url)
        projects.append(project)
        projects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        save()
        return project
    }

    /// Reconcile the in-memory project list with the contents of
    /// `projectsRoot`. The directory is the source of truth — anything
    /// the user `mkdir`'d there shows up automatically, anything that
    /// was deleted/moved disappears. We persist stable IDs in
    /// projects.json so the same folder keeps the same identity across
    /// launches (which keeps SwiftUI window restoration sane).
    func refresh() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var byPath: [String: Project] = [:]
        for project in projects {
            byPath[project.rootPath.standardizedFileURL.path] = project
        }

        var refreshed: [Project] = []
        for url in contents {
            let standardized = url.standardizedFileURL
            guard !Self.isReservedProjectFolderName(standardized.lastPathComponent) else { continue }
            let resources = try? standardized.resourceValues(forKeys: [
                .isDirectoryKey, .creationDateKey,
            ])
            guard resources?.isDirectory == true else { continue }

            let folderName = standardized.lastPathComponent
            if let existing = byPath[standardized.path] {
                if existing.name == folderName {
                    refreshed.append(existing)
                } else {
                    // Folder was renamed on disk — keep the identity and
                    // any user-chosen icon/tint, only the name follows.
                    refreshed.append(Project(
                        id: existing.id,
                        name: folderName,
                        rootPath: standardized,
                        createdAt: existing.createdAt,
                        symbol: existing.symbol,
                        tintHex: existing.tintHex
                    ))
                }
            } else {
                refreshed.append(Project(
                    name: folderName,
                    rootPath: standardized,
                    createdAt: resources?.creationDate ?? .now
                ))
            }
        }

        refreshed.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        projects = refreshed
        save()
    }

    /// Set (or clear, with nil) the project's custom glyph symbol.
    func setSymbol(_ symbol: String?, for id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].symbol = symbol
        save()
    }

    /// Set (or clear, with nil) the project's custom tint, stored as a
    /// `#RRGGBB` hex string.
    func setTintHex(_ hex: String?, for id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].tintHex = hex
        save()
    }

    /// Move the project's folder to the Trash. The list refreshes on the
    /// next scan; we also drop the entry locally so the home view updates
    /// immediately. We use the system trash (not `removeItem`) so the
    /// user can recover the project from Finder if they change their mind.
    func deleteProject(_ project: Project) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: project.rootPath.path) {
            var trashedURL: NSURL?
            try fm.trashItem(at: project.rootPath, resultingItemURL: &trashedURL)
        }
        projects.removeAll { $0.id == project.id }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Project].self, from: data)
        else { return }

        // Drop entries whose folder has gone missing — the user moved or
        // deleted them outside Dreamux.
        projects = decoded.filter { FileManager.default.fileExists(atPath: $0.rootPath.path) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(projects) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}
