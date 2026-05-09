import Foundation
import SwiftUI

struct Workspace: Identifiable, Hashable {
    let id: UUID
    var name: String
    var symbol: String
    var tint: Color
    var workingDirectory: String?

    init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "terminal.fill",
        tint: Color = .accentColor,
        workingDirectory: String? = nil
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.workingDirectory = workingDirectory
    }
}
