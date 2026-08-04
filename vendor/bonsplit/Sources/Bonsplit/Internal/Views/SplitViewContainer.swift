import SwiftUI

/// Main container view that renders the entire split tree (internal implementation)
struct SplitViewContainer<Content: View, EmptyContent: View, Accessory: View>: View {
    @Environment(SplitViewController.self) private var controller

    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    let tabBarAccessoryBuilder: (PaneID) -> Accessory
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch
    var onGeometryChange: ((_ isDragging: Bool) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            splitNodeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusable()
                .focusEffectDisabled()
                .onChange(of: geometry.size) { _, newSize in
                    updateContainerFrame(geometry: geometry)
                }
                .onAppear {
                    updateContainerFrame(geometry: geometry)
                }
        }
    }

    private func updateContainerFrame(geometry: GeometryProxy) {
        // Get frame in global coordinate space
        let frame = geometry.frame(in: .global)
        controller.containerFrame = frame
        onGeometryChange?(false)  // Container resize is not a drag
    }

    @ViewBuilder
    private var splitNodeContent: some View {
        SplitNodeView(
            node: controller.rootNode,
            contentBuilder: contentBuilder,
            emptyPaneBuilder: emptyPaneBuilder,
            tabBarAccessoryBuilder: tabBarAccessoryBuilder,
            showSplitButtons: showSplitButtons,
            contentViewLifecycle: contentViewLifecycle,
            onGeometryChange: onGeometryChange
        )
    }
}
