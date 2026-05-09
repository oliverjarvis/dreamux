import Foundation

struct Project: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var rootPath: URL
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        rootPath: URL,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.createdAt = createdAt
    }
}
