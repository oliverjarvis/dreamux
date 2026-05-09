import Foundation
import SwiftUI

struct Workspace: Identifiable, Hashable {
    let id: UUID
    var name: String
    var symbol: String
    var tint: Color
    var workingDirectory: String?
    /// The repository (by directory name under <project>/repos/) this
    /// work item belongs to. Nil means it's a free-floating workspace
    /// rooted at the project itself.
    var repoID: String?

    init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "terminal.fill",
        tint: Color = .accentColor,
        workingDirectory: String? = nil,
        repoID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.workingDirectory = workingDirectory
        self.repoID = repoID
    }
}
