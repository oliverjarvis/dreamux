import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore

    @State private var section: AppSection = .features
    @State private var railWidth: CGFloat = OuterRail.collapsedWidth

    var body: some View {
        HStack(spacing: 0) {
            OuterRail(selection: $section, width: $railWidth)
                .frame(width: railWidth)

            Divider()

            sectionDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var sectionDetail: some View {
        switch section {
        case .features:
            FeaturesDetail(store: store)
        }
    }
}

/// The previous top-level layout — workspace siderail plus the
/// tabs/terminals pane — now lives behind the "Features" section.
private struct FeaturesDetail: View {
    @Bindable var store: WorkspaceStore

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceSidebar(store: store)
                .frame(width: 92)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)

            Divider()

            WorkspaceTerminalContainer(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
