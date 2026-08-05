import SwiftUI

/// Builds the context menu for one tab chip. `AnyView` rather than a
/// generic: the accessory slot's builder is threaded through six view
/// types, and a second generic parameter would have to follow it through
/// all of them. Menu content is built per right-click and never diffed,
/// so the erasure costs nothing measurable.
public typealias TabContextMenuBuilder = @MainActor (Tab, PaneID) -> AnyView

/// Environment box for the optional builder. `nil` means "this host
/// wants no tab context menu" — which matters, because an empty
/// `.contextMenu` still shows an empty popup on right-click.
public struct TabContextMenuBox {
    public let builder: TabContextMenuBuilder?

    public init(_ builder: TabContextMenuBuilder? = nil) {
        self.builder = builder
    }

    public static let none = TabContextMenuBox(nil)
}

private struct TabContextMenuKey: EnvironmentKey {
    static let defaultValue = TabContextMenuBox.none
}

extension EnvironmentValues {
    var tabContextMenu: TabContextMenuBox {
        get { self[TabContextMenuKey.self] }
        set { self[TabContextMenuKey.self] = newValue }
    }
}
