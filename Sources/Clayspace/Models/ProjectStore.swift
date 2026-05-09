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
/// themselves live under ~/Documents/Clayspace by default so the user
/// can browse them in Finder.
@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [Project] = []

    let projectsRoot: URL
    private let storeURL: URL

    init() {
        let fm = FileManager.default

        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        let appDir = appSupport.appendingPathComponent("Clayspace", isDirectory: true)
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.storeURL = appDir.appendingPathComponent("projects.json")

        let documents = (try? fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents")
        let projectsRoot = documents.appendingPathComponent("Clayspace", isDirectory: true)
        try? fm.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        self.projectsRoot = projectsRoot

        load()
    }

    func project(id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

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
        save()
        return project
    }

    func remove(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Project].self, from: data)
        else { return }

        // Drop entries whose folder has gone missing — the user moved or
        // deleted them outside Clayspace.
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
