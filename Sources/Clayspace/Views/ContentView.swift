import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore
    @Bindable var repoStore: RepoStore

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
            FeaturesDetail(store: store, repoStore: repoStore)
        }
    }
}

/// The previous top-level layout — workspace siderail plus the
/// tabs/terminals pane — now lives behind the "Features" section.
private struct FeaturesDetail: View {
    @Bindable var store: WorkspaceStore
    @Bindable var repoStore: RepoStore

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceSidebar(store: store, repoStore: repoStore)
                .frame(width: 220)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)

            Divider()

            WorkspaceTerminalContainer(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
