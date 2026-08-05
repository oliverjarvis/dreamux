import AppKit
import SwiftUI
import Bonsplit

/// Process entry point. A CLI subcommand (`dreamux clone …`, `add …`, `list`)
/// runs headless and exits before any GUI is created; anything else launches
/// the SwiftUI app as usual. Sharing one binary keeps the CLI byte-compatible
/// with the app's own project store and git layout — no duplicate logic.
@main
struct DreamuxMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let command = arguments.first, DreamuxCLI.commandNames.contains(command) {
            exit(DreamuxCLI.run(arguments))
        }
        DreamuxApp.main()
    }
}

/// ⌘Q guard: quitting is instant when the app is idle, but killable work
/// (agent runs, foreground terminal jobs) gets one native confirmation.
/// Bypassed in e2e mode — automated runs quit programmatically and must
/// never hang on a modal.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !E2EMode.isActive,
              let summary = QuitGuard.shared.busySummary() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Dreamux?"
        alert.informativeText = summary
        // Cancel is first so it owns Return (Esc maps to it by title) —
        // a panicked double-tap can't quit.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct DreamuxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var projects = ProjectStore()

    init() {
        // Touch the signals bus so SQLite + the emit socket come up
        // before any project session or external MCP client needs them.
        _ = SignalBus.shared

        // Standard titlebar behaviors on the custom chrome (drag + double-click
        // zoom) — .hiddenTitleBar removes them; this puts them back app-wide.
        WindowChromeInteractions.install()

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

        // Clicking a banner raises Dreamux and lands on the exact tab the
        // agent is waiting in — installed unconditionally so the e2e
        // harness exercises the same path.
        NotificationManager.shared.onRoute = { route in
            NSApp.activate(ignoringOtherApps: true)
            WorkspaceStore.routeNotification(route)
        }
    }

    var body: some Scene {
        WindowGroup("Project", id: "project", for: UUID.self) { $projectID in
            ProjectRootView(projectID: $projectID, projects: projects)
                // Central type bump: every semantic font (.body/.callout/
                // .caption…) in the window scales up one Dynamic Type
                // notch — fixed-size fonts were swept up separately.
                .dynamicTypeSize(.xLarge)
        }
        // Custom chrome: no system titlebar/toolbar — ContentView draws
        // its own thin top bar (the traffic lights overlay it at their
        // standard spot). The system toolbar's safe-area machinery kept
        // fighting the inset-card layout (edge-extension heuristics,
        // swallowed gutters); owning the bar makes layout deterministic.
        .windowStyle(.hiddenTitleBar)
        .commands {
            ProjectCommands()
            FileExplorerCommands()
            PaletteCommands()
            PrintCommandRemoval()
            IntegrationCommands()
            NotificationCommands()
        }

        // ⌘, / app-menu "Settings…" — appearance knobs for the chrome.
        Settings {
            SettingsView()
        }

        // The global Applet Studio window — the canonical applet library,
        // opened from the projects rail rather than any one project.
        Window("Applet Studio", id: "app-studio") {
            AppStudioView()
        }
    }
}

// MARK: - Window root

/// Routes a project window between three states: a live project, the
/// launch gate (no project bound — launch or after the last project was
/// deleted), or the missing-project fallback (the bound project's folder
/// vanished, usually deleted from another window).
private struct ProjectRootView: View {
    @Binding var projectID: UUID?
    let projects: ProjectStore

    var body: some View {
        if let id = projectID {
            if let project = projects.project(id: id) {
                ProjectWindow(
                    project: project,
                    onSwitchProject: { projectID = $0 }
                )
                .environment(projects)
                .frame(minWidth: 720, minHeight: 480)
            } else {
                MissingProjectView(onContinue: { projectID = nil })
                    .frame(minWidth: 480, minHeight: 320)
            }
        } else {
            LaunchGate(projectID: $projectID, projects: projects)
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}

/// Decides where a project-less window lands. With projects present it
/// rewrites the window's binding to the right one (routing straight into
/// it); with none it shows `WelcomeView`. This replaces the old Home
/// window's one-shot launch redirect — with no Home to return to,
/// re-resolving a nil window is always correct.
private struct LaunchGate: View {
    @Binding var projectID: UUID?
    let projects: ProjectStore

    var body: some View {
        Group {
            if projects.projects.isEmpty {
                WelcomeView(store: projects, onOpenProject: { projectID = $0 })
            } else {
                Color.clear
            }
        }
        .task(resolve)
    }

    /// Awaits the folder scan before routing: the scan runs off-main (an
    /// iCloud sync stall must never wedge launch), but picking a window
    /// destination — and e2e auto-open matching — needs its result.
    @Sendable private func resolve() async {
        await projects.refreshAndWait()
        // e2e convenience: jump straight into the named project's window
        // so drivers don't script project selection. Falls through to
        // normal launch routing when the name doesn't match a discovered
        // project.
        if let name = E2EMode.autoOpenProjectName,
           let match = projects.projects.first(where: { $0.name == name }) {
            projectID = match.id
            return
        }
        switch LaunchDestination.resolve(
            lastOpenedID: LastOpenedProject.load(),
            projects: projects.projects
        ) {
        case .project(let id):
            projectID = id
        case .welcome:
            break // WelcomeView is already on screen.
        }
    }
}

// MARK: - View commands

/// The View-menu toggle for the right-side file explorer, carrying the
/// ⌥⌘E shortcut. This lives in `.commands` (rather than a toolbar-item
/// shortcut) on purpose: a `.keyboardShortcut` attached to a toolbar item
/// is not dispatched while the Ghostty terminal NSView is first responder
/// — it just rings the system bell. Menu key equivalents are resolved by
/// the main menu ahead of the responder chain, so they fire regardless of
/// focus. It reaches the focused window's `showFileTree` state via
/// `@FocusedBinding`, mirroring how `ProjectCommands` reaches the active
/// `WorkspaceStore`.
private struct FileExplorerCommands: Commands {
    @FocusedBinding(\.fileTreeVisible) private var fileTreeVisible: Bool?

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button((fileTreeVisible ?? false) ? "Hide File Explorer" : "Show File Explorer") {
                fileTreeVisible?.toggle()
            }
            .keyboardShortcut("e", modifiers: [.option, .command])
            .disabled(fileTreeVisible == nil)
        }
    }
}

/// Removes the default Print/Page Setup items — nothing in Dreamux
/// prints, and freeing ⌘P lets the File menu's "New Plan…" own it.
private struct PrintCommandRemoval: Commands {
    var body: some Commands {
        CommandGroup(replacing: .printItem) {}
    }
}

/// View-menu toggle for the ⌘K command palette. Same `.commands` +
/// `@FocusedBinding` bridge as `FileExplorerCommands` — the shortcut
/// must fire while a terminal is first responder. No palette over
/// modals: while a sheet is presented, AppKit makes the sheet ITSELF
/// the key window (not the presenting window), and a sheet's own
/// `attachedSheet` is nil — so the guard below checks `isSheet` on
/// the key window too, not just `attachedSheet`.
private struct PaletteCommands: Commands {
    @FocusedBinding(\.palettePresented) private var palettePresented: Bool?

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Command Palette…") {
                if let key = NSApp.keyWindow, key.isSheet || key.attachedSheet != nil { return }
                palettePresented?.toggle()
            }
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(palettePresented == nil)
        }
    }
}

// MARK: - Integration commands

private struct IntegrationCommands: Commands {
    var body: some Commands {
        CommandMenu("Integrations") {
            Button("Reveal Dreamux Bin Directory") {
                guard let dir = ClaudeCodeIntegration.shimDirectory else { return }
                NSWorkspace.shared.open(dir)
            }
            .disabled(ClaudeCodeIntegration.shimDirectory == nil)
        }
    }
}

// MARK: - Missing project fallback

private struct MissingProjectView: View {
    /// Clear this window's project so the launch gate re-resolves
    /// (routing to another project, or Welcome when none remain).
    let onContinue: () -> Void

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
            Button("Continue", action: onContinue)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - App menu commands

private struct NotificationCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Notification Settings…") {
                NotificationManager.shared.openSystemNotificationSettings()
            }
            Button("Run Notification Diagnostic") {
                NotificationManager.shared.runDiagnostic()
            }
        }
    }
}

// MARK: - Project commands

private struct ProjectCommands: Commands {
    @FocusedValue(\.activeStore) private var store: WorkspaceStore?
    @FocusedBinding(\.createProjectPresented) private var createProjectPresented: Bool?
    @FocusedBinding(\.newPlanPresented) private var newPlanPresented: Bool?
    @FocusedBinding(\.newAppletPresented) private var newAppletPresented: Bool?
    @FocusedBinding(\.openBrowserRequested) private var openBrowserRequested: Bool?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project…") {
                createProjectPresented = true
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(createProjectPresented == nil)

            Button("New Idea…") {
                newPlanPresented = true
            }
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(newPlanPresented == nil)

            Button("New Applet…") {
                newAppletPresented = true
            }
            .keyboardShortcut("l", modifiers: [.command])
            .disabled(newAppletPresented == nil)

            // No focused value on purpose: parking an intent + opening the window
            // works from EVERY window (App Studio and Settings included), so the
            // item is never disabled.
            Button("New Global Applet…") {
                AppStudioIntents.shared.pendingNewApplet = true
                openWindow(id: "app-studio")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            Button("New Tab") {
                store?.activeSession?.createTab()
            }
            .keyboardShortcut("t", modifiers: [.command])
            .disabled(store == nil)

            Button("Open Browser") {
                openBrowserRequested = true
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(openBrowserRequested == nil)

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
