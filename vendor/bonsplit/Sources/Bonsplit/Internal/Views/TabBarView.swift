import SwiftUI
import UniformTypeIdentifiers

/// Tab bar view with scrollable tabs, drag/drop support, and split buttons
struct TabBarView: View {
    @Environment(BonsplitController.self) private var controller
    @Environment(SplitViewController.self) private var splitViewController
    
    @Bindable var pane: PaneState
    let isFocused: Bool
    var showSplitButtons: Bool = true

    @State private var dropTargetIndex: Int?
    @State private var scrollOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    /// Each tab's frame in the "tabScroll" coordinate space, keyed by
    /// index -- the same space `scrollOffset`/`contentWidth` are
    /// measured in (see the `TabFramePreferenceKey` collection below).
    /// Used to map a file drag's x-position to an insertion index.
    @State private var tabFrames: [Int: CGRect] = [:]
    /// Insertion index a file drag (tracked via `TabBarFileDropAnchor`)
    /// currently resolves to, or nil when no file drag is hovering this
    /// bar. Drives the same `dropIndicator` tab-reordering shows.
    @State private var fileDropIndex: Int?

    private var canScrollLeft: Bool {
        scrollOffset > 1
    }

    private var canScrollRight: Bool {
        contentWidth > containerWidth && scrollOffset < contentWidth - containerWidth - 1
    }

    /// Whether this tab bar should show full saturation (focused or drag source)
    private var shouldShowFullSaturation: Bool {
        isFocused || splitViewController.dragSourcePaneId == pane.id
    }

    var body: some View {
        HStack(spacing: 0) {
            // Scrollable tabs with fade overlays
            GeometryReader { containerGeo in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: TabBarMetrics.tabSpacing) {
                            ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                                tabItem(for: tab, at: index)
                                    .id(tab.id)
                            }

                            // Drop zone at end of tabs
                            dropZoneAtEnd
                        }
                        .padding(.horizontal, TabBarMetrics.barPadding)
                        // Stretch the row to fill the visible bar so the
                        // flexible `dropZoneAtEnd` (`maxWidth: .infinity`)
                        // absorbs the run-off after the last tab and
                        // accepts append-to-end drops in that empty area.
                        .frame(minWidth: containerGeo.size.width, alignment: .leading)
                        .background(
                            GeometryReader { contentGeo in
                                Color.clear
                                    .onChange(of: contentGeo.frame(in: .named("tabScroll"))) { _, newFrame in
                                        scrollOffset = -newFrame.minX
                                        contentWidth = newFrame.width
                                    }
                                    .onAppear {
                                        let frame = contentGeo.frame(in: .named("tabScroll"))
                                        scrollOffset = -frame.minX
                                        contentWidth = frame.width
                                    }
                            }
                        )
                    }
                    .coordinateSpace(name: "tabScroll")
                    .onAppear {
                        containerWidth = containerGeo.size.width
                        if let tabId = pane.selectedTabId {
                            proxy.scrollTo(tabId, anchor: .center)
                        }
                    }
                    .onChange(of: containerGeo.size.width) { _, newWidth in
                        containerWidth = newWidth
                    }
                    .onChange(of: pane.selectedTabId) { _, newTabId in
                        if let tabId = newTabId {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(tabId, anchor: .center)
                            }
                        }
                    }
                    .onPreferenceChange(TabFramePreferenceKey.self) { frames in
                        tabFrames = frames
                    }
                }
                .frame(height: TabBarMetrics.barHeight)
                .overlay(fadeOverlays)
            }

            Spacer()

            // Split buttons
            if showSplitButtons {
                splitButtons
            }
        }
        .frame(height: TabBarMetrics.barHeight)
        .contentShape(Rectangle())
        .background(tabBarBackground)
        .saturation(shouldShowFullSaturation ? 1.0 : 0)
        // Whole-strip file drop target: on/between tabs and in the empty
        // trailing area. SwiftUI's `.onDrop`/`.dropDestination` never
        // fired here (see `TabBarFileDropAnchor`'s doc comment for why),
        // so this is a window-level AppKit overlay frame-synced to the
        // bar instead of a SwiftUI drop modifier. It reports the drag's
        // x-position rather than drawing anything itself, so the same
        // `dropIndicator` used for tab reordering can track it.
        .background(TabBarFileDropAnchor(
            onHoverX: { x in
                fileDropIndex = x.map(fileDropInsertionIndex(forBarLocalX:))
            },
            onDropAtX: { urls, x in
                let index = fileDropInsertionIndex(forBarLocalX: x)
                fileDropIndex = nil
                controller.notifyFileDrop(urls, inPane: pane.id, atIndex: index)
            }
        ))
    }

    // MARK: - File Drop Index Mapping

    /// Maps a file drag's anchor-local x (from `TabBarFileDropAnchor`,
    /// whose bounds cover the whole bar) to a tab insertion index, using
    /// the same "tabScroll" coordinate space `tabFrames` are captured in.
    ///
    /// The anchor and the scrollable tab row share an origin (the
    /// `GeometryReader` is the leading, spacing-0 child of the bar's
    /// outer `HStack`, and the `ScrollView` fills it exactly), so the
    /// reported x is already relative to the *visible* (scrolled)
    /// viewport in that same space. `scrollOffset` is tracked as
    /// `-contentFrame.minX` (see the `onChange`/`onAppear` above this
    /// computes it in), i.e. how far the content has scrolled left of
    /// its own origin -- so adding it back converts a viewport-relative
    /// x into the content-relative x the tab frames are measured in.
    private func fileDropInsertionIndex(forBarLocalX x: CGFloat) -> Int {
        let contentX = x + scrollOffset
        for index in 0..<pane.tabs.count {
            if let frame = tabFrames[index], contentX < frame.midX {
                return index
            }
        }
        return pane.tabs.count
    }

    // MARK: - Tab Item

    @ViewBuilder
    private func tabItem(for tab: TabItem, at index: Int) -> some View {
        TabItemView(
            tab: tab,
            isSelected: pane.selectedTabId == tab.id,
            onSelect: {
                withAnimation(.easeInOut(duration: TabBarMetrics.selectionDuration)) {
                    pane.selectTab(tab.id)
                    controller.focusPane(pane.id)
                }
            },
            onClose: {
                withAnimation(.easeInOut(duration: TabBarMetrics.closeDuration)) {
                    _ = controller.closeTab(TabID(id: tab.id), inPane: pane.id)
                }
            }
        )
        .onDrag {
            createItemProvider(for: tab)
        } preview: {
            TabDragPreview(tab: tab)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(
            targetIndex: index,
            pane: pane,
            controller: splitViewController,
            dropTargetIndex: $dropTargetIndex
        ))
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TabFramePreferenceKey.self,
                    value: [index: geo.frame(in: .named("tabScroll"))]
                )
            }
        )
        .overlay(alignment: .leading) {
            if dropTargetIndex == index || fileDropIndex == index {
                dropIndicator
            }
        }
    }

    // MARK: - Item Provider

    private func createItemProvider(for tab: TabItem) -> NSItemProvider {
        // Set drag source for visual feedback
        splitViewController.draggingTab = tab
        splitViewController.dragSourcePaneId = pane.id

        let transfer = TabTransferData(tab: tab, sourcePaneId: pane.id.id)
        if let data = try? JSONEncoder().encode(transfer),
           let string = String(data: data, encoding: .utf8) {
            return NSItemProvider(object: string as NSString)
        }
        return NSItemProvider()
    }

    // MARK: - Drop Zone at End

    @ViewBuilder
    private var dropZoneAtEnd: some View {
        // Flexible width so this zone expands across all empty space after
        // the last tab when the row is stretched (see HStack's minWidth).
        // Drops anywhere in the trailing run-off resolve to "append to end".
        Rectangle()
            .fill(Color.clear)
            .frame(minWidth: 30, maxWidth: .infinity)
            .frame(height: TabBarMetrics.tabHeight)
            .contentShape(Rectangle())
            .onDrop(of: [.text], delegate: TabDropDelegate(
                targetIndex: pane.tabs.count,
                pane: pane,
                controller: splitViewController,
                dropTargetIndex: $dropTargetIndex
            ))
            .overlay(alignment: .leading) {
                if dropTargetIndex == pane.tabs.count || fileDropIndex == pane.tabs.count {
                    dropIndicator
                }
            }
    }

    // MARK: - Drop Indicator

    @ViewBuilder
    private var dropIndicator: some View {
        Capsule()
            .fill(TabBarColors.dropIndicator)
            .frame(width: TabBarMetrics.dropIndicatorWidth, height: TabBarMetrics.dropIndicatorHeight)
            .offset(x: -1)
            .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Split Buttons

    @ViewBuilder
    private var splitButtons: some View {
        HStack(spacing: 4) {
            Button {
                // 120fps animation handled by SplitAnimator
                controller.splitPane(pane.id, orientation: .horizontal)
            } label: {
                Image(systemName: "square.split.2x1")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Split Right")

            Button {
                // 120fps animation handled by SplitAnimator
                controller.splitPane(pane.id, orientation: .vertical)
            } label: {
                Image(systemName: "square.split.1x2")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Split Down")
        }
        .padding(.trailing, 8)
    }

    // MARK: - Fade Overlays

    @ViewBuilder
    private var fadeOverlays: some View {
        let fadeWidth: CGFloat = 24

        HStack(spacing: 0) {
            // Left fade
            LinearGradient(
                colors: [TabBarColors.barBackground, TabBarColors.barBackground.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)
            .opacity(canScrollLeft ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: canScrollLeft)
            .allowsHitTesting(false)

            Spacer()

            // Right fade
            LinearGradient(
                colors: [TabBarColors.barBackground.opacity(0), TabBarColors.barBackground],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)
            .opacity(canScrollRight ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: canScrollRight)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var tabBarBackground: some View {
        Rectangle()
            .fill(isFocused ? TabBarColors.barBackground : TabBarColors.barBackground.opacity(0.95))
            // Recess the strip so the brighter, content-colored active tab
            // reads as merged with the pane while inactive tabs sit on the bar.
            .overlay(TabBarColors.barRecess)
            // Baseline dividing bar from content — the active tab's opaque
            // fill covers its own segment, breaking the line where it merges.
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(TabBarColors.separator)
                    .frame(height: 1)
            }
    }
}

// MARK: - Tab Frame Preference Key

/// Collects each rendered tab's frame (in the "tabScroll" coordinate
/// space), keyed by index, so `TabBarView` can map a file drag's
/// x-position to an insertion index. Merges by index since every tab
/// reports its own single-entry dictionary.
struct TabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Tab Drop Delegate

struct TabDropDelegate: DropDelegate {
    let targetIndex: Int
    let pane: PaneState
    let controller: SplitViewController
    @Binding var dropTargetIndex: Int?

    func performDrop(info: DropInfo) -> Bool {
        dropTargetIndex = nil

        guard let provider = info.itemProviders(for: [.text]).first else {
            // Clear drag state
            controller.draggingTab = nil
            controller.dragSourcePaneId = nil
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
            DispatchQueue.main.async {
                // Clear drag state
                controller.draggingTab = nil
                controller.dragSourcePaneId = nil

                // Handle both Data and String representations
                let string: String?
                if let data = item as? Data {
                    string = String(data: data, encoding: .utf8)
                } else if let nsString = item as? NSString {
                    string = nsString as String
                } else if let str = item as? String {
                    string = str
                } else {
                    string = nil
                }

                guard let string, let transfer = decodeTransfer(from: string) else {
                    return
                }

                // Same pane - reorder
                if transfer.sourcePaneId == pane.id.id {
                    guard let sourceIndex = pane.tabs.firstIndex(where: { $0.id == transfer.tab.id }) else {
                        return
                    }
                    withAnimation(.spring(duration: TabBarMetrics.reorderDuration, bounce: TabBarMetrics.reorderBounce)) {
                        pane.moveTab(from: sourceIndex, to: targetIndex)
                    }
                } else {
                    // Different pane - transfer
                    guard let sourcePaneId = controller.rootNode.allPaneIds.first(where: { $0.id == transfer.sourcePaneId }) else {
                        return
                    }
                    withAnimation(.spring(duration: TabBarMetrics.reorderDuration, bounce: TabBarMetrics.reorderBounce)) {
                        controller.moveTab(transfer.tab, from: sourcePaneId, to: pane.id, atIndex: targetIndex)
                    }
                }
            }
        }

        return true
    }

    func dropEntered(info: DropInfo) {
        dropTargetIndex = targetIndex
    }

    func dropExited(info: DropInfo) {
        if dropTargetIndex == targetIndex {
            dropTargetIndex = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    private func decodeTransfer(from string: String) -> TabTransferData? {
        guard let data = string.data(using: .utf8),
              let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data) else {
            return nil
        }
        return transfer
    }
}


