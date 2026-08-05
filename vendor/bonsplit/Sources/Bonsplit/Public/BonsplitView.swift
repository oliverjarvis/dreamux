import SwiftUI

/// Main entry point for the Bonsplit library
///
/// Usage:
/// ```swift
/// struct MyApp: View {
///     @State private var controller = BonsplitController()
///
///     var body: some View {
///         BonsplitView(controller: controller) { tab, paneId in
///             MyContentView(for: tab)
///                 .onTapGesture { controller.focusPane(paneId) }
///         } emptyPane: { paneId in
///             Text("Empty pane")
///         } tabBarAccessory: { paneId in
///             Button("+") { controller.createTab(title: "New", inPane: paneId) }
///         }
///     }
/// }
/// ```
public struct BonsplitView<Content: View, EmptyContent: View, Accessory: View>: View {
    @Bindable private var controller: BonsplitController
    private let contentBuilder: (Tab, PaneID) -> Content
    private let emptyPaneBuilder: (PaneID) -> EmptyContent
    private let tabBarAccessoryBuilder: (PaneID) -> Accessory
    private let tabContextMenu: TabContextMenuBuilder?

    /// Initialize with a controller, content builder, empty pane builder, and tab bar accessory
    /// - Parameters:
    ///   - controller: The BonsplitController managing the tab state
    ///   - tabContextMenu: Optional per-tab context menu. Receives the tab and
    ///     its pane; return the menu's content. Nil (the default) attaches no
    ///     menu at all — an empty `.contextMenu` would still open an empty
    ///     popup on right-click.
    ///   - content: A ViewBuilder closure that provides content for each tab. Receives the tab and pane ID.
    ///   - emptyPane: A ViewBuilder closure that provides content for empty panes
    ///   - tabBarAccessory: A ViewBuilder closure rendered in each pane's tab bar, in the trailing
    ///     cluster just leading of the split buttons. Receives that pane's ID. Bonsplit places the
    ///     slot and knows nothing about what goes in it.
    public init(
        controller: BonsplitController,
        tabContextMenu: TabContextMenuBuilder? = nil,
        @ViewBuilder content: @escaping (Tab, PaneID) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent,
        @ViewBuilder tabBarAccessory: @escaping (PaneID) -> Accessory
    ) {
        self.controller = controller
        self.tabContextMenu = tabContextMenu
        self.contentBuilder = content
        self.emptyPaneBuilder = emptyPane
        self.tabBarAccessoryBuilder = tabBarAccessory
    }

    public var body: some View {
        SplitViewContainer(
            contentBuilder: { tabItem, paneId in
                contentBuilder(Tab(from: tabItem), PaneID(id: paneId.id))
            },
            emptyPaneBuilder: { internalPaneId in
                emptyPaneBuilder(PaneID(id: internalPaneId.id))
            },
            tabBarAccessoryBuilder: { internalPaneId in
                tabBarAccessoryBuilder(PaneID(id: internalPaneId.id))
            },
            showSplitButtons: controller.configuration.allowSplits && controller.configuration.appearance.showSplitButtons,
            contentViewLifecycle: controller.configuration.contentViewLifecycle,
            onGeometryChange: { [weak controller] isDragging in
                controller?.notifyGeometryChange(isDragging: isDragging)
            }
        )
        .environment(controller)
        .environment(controller.internalController)
        .environment(\.tabContextMenu, TabContextMenuBox(tabContextMenu))
    }
}

// MARK: - Convenience initializers

extension BonsplitView where Accessory == EmptyView {
    /// Initialize without a tab bar accessory — the tab bar renders as it
    /// always has (tab strip, then the split buttons).
    /// - Parameters:
    ///   - controller: The BonsplitController managing the tab state
    ///   - content: A ViewBuilder closure that provides content for each tab. Receives the tab and pane ID.
    ///   - emptyPane: A ViewBuilder closure that provides content for empty panes
    ///   - tabContextMenu: Optional per-tab context menu; nil attaches none.
    public init(
        controller: BonsplitController,
        tabContextMenu: TabContextMenuBuilder? = nil,
        @ViewBuilder content: @escaping (Tab, PaneID) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent
    ) {
        self.controller = controller
        self.tabContextMenu = tabContextMenu
        self.contentBuilder = content
        self.emptyPaneBuilder = emptyPane
        self.tabBarAccessoryBuilder = { _ in EmptyView() }
    }
}

extension BonsplitView where EmptyContent == DefaultEmptyPaneView, Accessory == EmptyView {
    /// Initialize with a controller and content builder, using the default empty pane view
    /// - Parameters:
    ///   - controller: The BonsplitController managing the tab state
    ///   - content: A ViewBuilder closure that provides content for each tab. Receives the tab and pane ID.
    ///   - tabContextMenu: Optional per-tab context menu; nil attaches none.
    public init(
        controller: BonsplitController,
        tabContextMenu: TabContextMenuBuilder? = nil,
        @ViewBuilder content: @escaping (Tab, PaneID) -> Content
    ) {
        self.controller = controller
        self.tabContextMenu = tabContextMenu
        self.contentBuilder = content
        self.emptyPaneBuilder = { _ in DefaultEmptyPaneView() }
        self.tabBarAccessoryBuilder = { _ in EmptyView() }
    }
}

/// Default view shown when a pane has no tabs
public struct DefaultEmptyPaneView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No Open Tabs")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
