import Foundation

struct Project: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var rootPath: URL
    var createdAt: Date
    /// User-chosen SF Symbol for the project glyph; nil falls back to the
    /// initial-letter glyph.
    var symbol: String?
    /// User-chosen tint as `#RRGGBB`; nil falls back to a stable color
    /// derived from the name.
    var tintHex: String?

    init(
        id: UUID = UUID(),
        name: String,
        rootPath: URL,
        createdAt: Date = .now,
        symbol: String? = nil,
        tintHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.createdAt = createdAt
        self.symbol = symbol
        self.tintHex = tintHex
    }
}
