import Foundation

enum PlanTaskTitle {
    /// Strip a leading `Task N:` / `Task N.M:` from a heading (a node/row
    /// already carries the ordinal); keep any other title verbatim; an empty
    /// title reads as "Steps".
    static func clean(_ title: String) -> String {
        if let r = title.range(of: #"^Task\s+\d+(?:\.\d+)*:\s*"#, options: .regularExpression) {
            let rest = String(title[r.upperBound...])
            return rest.isEmpty ? "Steps" : rest
        }
        return title.isEmpty ? "Steps" : title
    }
}
