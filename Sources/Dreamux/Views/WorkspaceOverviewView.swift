import SwiftUI

/// The workspace's home dashboard — its pinned, non-dismissable first
/// tab. Placeholder for now; Groups 2–3 fill in the plan-backed run
/// dashboard (Mode A) and the plain-workspace overview (Mode B).
struct WorkspaceOverviewView: View {
    @Bindable var session: WorkspaceSession

    var body: some View {
        VStack {
            Text("Overview")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
