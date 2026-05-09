import SwiftUI

struct ContentView: View {
    @Bindable var store: WorkspaceStore

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceSidebar(store: store)
                .frame(width: 64)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)

            Divider()

            WorkspaceTerminalContainer(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
