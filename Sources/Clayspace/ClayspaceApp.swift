import SwiftUI
import Bonsplit

@main
struct ClayspaceApp: App {
    @State private var projects = ProjectStore()

    init() {
        if let socketPath = E2EMode.socketPath {
            // e2e harness launch: skip the notification permission
            // dialog (nothing can click it mid-run) and bring the
            // automation server up before any window exists, so the
            // driver's first ping lands no matter how fast it connects.
            E2ERegistry.shared.registerProjectStore(_projects.wrappedValue)
            E2EServer.start(socketPath: socketPath)
        } else {
            // Ask once at launch — the user can revoke later in System Settings.
            NotificationManager.shared.requestAuthorizationIfNeeded()
        }
    }

    var body: some Scene {
        Window("Clayspace", id: "home") {
            HomeView(store: projects)
        }
        .commands {
            HomeCommands()
        }

        WindowGroup("Project", id: "project", for: UUID.self) { $projectID in
            if let id = projectID, let project = projects.project(id: id) {
                ProjectWindow(
                    project: project,
                    onSwitchProject: { projectID = $0 }
                )
                .environment(projects)
                .frame(minWidth: 720, minHeight: 480)
            } else {
                MissingProjectView(store: projects)
                    .frame(minWidth: 480, minHeight: 320)
            }
        }
        .commands {
            ProjectCommands()
            IntegrationCommands()
        }
    }
}

// MARK: - Integration commands

private struct IntegrationCommands: Commands {
    var body: some Commands {
        CommandMenu("Integrations") {
            Button("Reveal Clayspace Bin Directory") {
                guard let dir = ClaudeCodeIntegration.shimDirectory else { return }
                NSWorkspace.shared.open(dir)
            }
            .disabled(ClaudeCodeIntegration.shimDirectory == nil)
        }
    }
}

// MARK: - Missing project fallback

private struct MissingProjectView: View {
    let store: ProjectStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Project unavailable").font(.headline)
            Text("This project's folder is missing or has been removed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Back to Home") {
                openWindow(id: "home")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Home commands

private struct HomeCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Show Home") { openWindow(id: "home") }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            Button("Notification Settings…") {
                NotificationManager.shared.openSystemNotificationSettings()
            }
        }
    }
}

// MARK: - Project commands

private struct ProjectCommands: Commands {
    @FocusedValue(\.activeStore) private var store: WorkspaceStore?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                store?.activeSession?.createTab()
            }
            .keyboardShortcut("t", modifiers: [.command])
            .disabled(store == nil)

            Button("New Workspace") {
                store?.addWorkspace()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(store == nil)

            Button("Reopen Closed Workspace") {
                store?.reopenClosedWorkspace()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift, .option])
            .disabled(!(store?.canReopenClosed ?? false))

            Divider()

            Button("Split Right") {
                store?.activeSession?.splitFocused(.horizontal)
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(store == nil)

            Button("Split Down") {
                store?.activeSession?.splitFocused(.vertical)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(store == nil)

            Divider()

            Button("Close Tab") {
                store?.activeSession?.closeFocusedTab()
            }
            .keyboardShortcut("w", modifiers: [.command])
            .disabled(store == nil)

            Button("Close Workspace") {
                if let store, let workspace = store.activeWorkspace {
                    store.remove(workspace)
                }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(store == nil)
        }

        CommandMenu("Navigate") {
            Button("Focus Left Pane") { store?.activeSession?.navigateFocus(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(store == nil)
            Button("Focus Right Pane") { store?.activeSession?.navigateFocus(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(store == nil)
            Button("Focus Pane Above") { store?.activeSession?.navigateFocus(.up) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(store == nil)
            Button("Focus Pane Below") { store?.activeSession?.navigateFocus(.down) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(store == nil)

            Divider()

            // We always emit nine workspace shortcuts so they're stable;
            // each one no-ops if there isn't a workspace at that index.
            ForEach(0..<9, id: \.self) { index in
                Button(workspaceLabel(at: index)) {
                    if let store, store.workspaces.indices.contains(index) {
                        store.activeID = store.workspaces[index].id
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
                .disabled(!hasWorkspace(at: index))
            }

            Divider()

            ForEach(0..<9, id: \.self) { index in
                Button("Tab \(index + 1)") {
                    store?.activeSession?.selectTab(at: index)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                .disabled(store == nil)
            }
        }
    }

    private func hasWorkspace(at index: Int) -> Bool {
        guard let store else { return false }
        return store.workspaces.indices.contains(index)
    }

    private func workspaceLabel(at index: Int) -> String {
        if let store, store.workspaces.indices.contains(index) {
            return "Workspace: \(store.workspaces[index].name)"
        }
        return "Workspace \(index + 1)"
    }
}
