import Foundation

/// Where a fresh launch should land. `welcome` (the create-your-first-
/// project screen) is shown only when there are no projects to open;
/// otherwise launch jumps straight into a project window — the remembered
/// last-opened project when it still exists, else the first project in
/// store order.
enum LaunchDestination: Equatable {
    case welcome
    case project(UUID)

    static func resolve(lastOpenedID: UUID?, projects: [Project]) -> LaunchDestination {
        guard !projects.isEmpty else { return .welcome }
        if let lastOpenedID, projects.contains(where: { $0.id == lastOpenedID }) {
            return .project(lastOpenedID)
        }
        return .project(projects[0].id)
    }
}

/// UserDefaults-backed memory of the project the user last had open.
/// Recording is a no-op under the e2e harness: sandboxed runs share the
/// process's real defaults domain, and the launch redirect is
/// suppressed there anyway.
enum LastOpenedProject {
    static let defaultsKey = "lastOpenedProjectID"

    static func record(_ id: UUID, in defaults: UserDefaults = .standard) {
        guard !E2EMode.isActive else { return }
        defaults.set(id.uuidString, forKey: defaultsKey)
    }

    static func load(from defaults: UserDefaults = .standard) -> UUID? {
        guard let raw = defaults.string(forKey: defaultsKey) else { return nil }
        return UUID(uuidString: raw)
    }
}
