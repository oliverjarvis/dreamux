import AppKit

/// Panel visibility, published for the e2e state dump only. `PipHost`'s
/// coordinator owns the panels; this just mirrors "is it on screen" by
/// pip id, so a driver can assert minimize/hide behaviour without
/// screenshots (which can't capture window contents in-process).
@MainActor
final class PipPanelRegistry {
    static let shared = PipPanelRegistry()
    private var visible: Set<UUID> = []

    func record(_ id: UUID, isVisible: Bool) {
        if isVisible { visible.insert(id) } else { visible.remove(id) }
    }

    func forget(_ id: UUID) { visible.remove(id) }

    func isVisible(_ id: UUID) -> Bool { visible.contains(id) }
}
