import SwiftUI
import Bonsplit

@main
struct ClayspaceApp: App {
    @State private var store = WorkspaceStore()

    var body: some Scene {
        WindowGroup("Clayspace") {
            ContentView(store: store)
                .frame(minWidth: 720, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    store.activeSession?.createTab()
                }
                .keyboardShortcut("t", modifiers: [.command])

                Button("New Workspace") {
                    store.addWorkspace()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button("Split Right") {
                    store.activeSession?.splitFocused(.horizontal)
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("Split Down") {
                    store.activeSession?.splitFocused(.vertical)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("Close Tab") {
                    store.activeSession?.closeFocusedTab()
                }
                .keyboardShortcut("w", modifiers: [.command])

                Button("Close Workspace") {
                    if let workspace = store.activeWorkspace {
                        store.remove(workspace)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }

            CommandMenu("Navigate") {
                Button("Focus Left Pane") { store.activeSession?.navigateFocus(.left) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Focus Right Pane") { store.activeSession?.navigateFocus(.right) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Focus Pane Above") { store.activeSession?.navigateFocus(.up) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Focus Pane Below") { store.activeSession?.navigateFocus(.down) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])

                Divider()

                ForEach(Array(store.workspaces.prefix(9).enumerated()), id: \.element.id) { index, workspace in
                    Button("Workspace: \(workspace.name)") {
                        store.activeID = workspace.id
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command])
                }

                Divider()

                ForEach(0..<9, id: \.self) { index in
                    Button("Tab \(index + 1)") {
                        store.activeSession?.selectTab(at: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                }
            }
        }
    }
}
