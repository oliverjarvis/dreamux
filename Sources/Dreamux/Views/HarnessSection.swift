import SwiftUI

/// Sidebar section listing the coding harnesses Dreamux found on `PATH`.
///
/// Only `userConfigBlock` harnesses get a toggle: they are the ones that
/// need Dreamux to write into a file it does not own, so they are the
/// ones there is anything to consent to. `processInjection` harnesses
/// (Claude Code) are already wired by the PATH shim and write nothing,
/// so they list as present and offer no switch.
///
/// The toggle labels name the exact file on purpose — the user is
/// consenting to a specific write, not to a vague "integration".
struct HarnessSection: View {
    @State private var installedIDs: Set<String> = []
    @State private var errors: [String: String] = [:]

    private let installer = HarnessConfigInstaller()

    private var harnesses: [HarnessAdapter] { HarnessRegistry.shared.installed() }

    var body: some View {
        if !harnesses.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SidebarSectionHeader(title: "Agents", icon: PhosphorIcon.puzzlePieceFill)
                SidebarSectionChildren {
                    ForEach(harnesses, id: \.id) { harness in
                        row(harness)
                    }
                }
            }
            .onAppear(perform: refresh)
        }
    }

    @ViewBuilder
    private func row(_ harness: HarnessAdapter) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(harness.displayName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)

            if harness.strategy == .userConfigBlock {
                Button(action: { toggle(harness) }) {
                    Text(installedIDs.contains(harness.id)
                         ? "Enabled — remove from ~/.cursor/hooks.json"
                         : "Enable — writes to ~/.cursor/hooks.json")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if let error = errors[harness.id] {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func configURL(for harness: HarnessAdapter) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/hooks.json")
    }

    private func refresh() {
        installedIDs = Set(
            harnesses
                .filter { $0.strategy == .userConfigBlock }
                .filter { installer.isInstalled(harnessID: $0.id, configURL: configURL(for: $0)) }
                .map(\.id)
        )
    }

    private func toggle(_ harness: HarnessAdapter) {
        let url = configURL(for: harness)
        errors[harness.id] = nil
        do {
            if installedIDs.contains(harness.id) {
                try installer.uninstall(harnessID: harness.id, configURL: url)
            } else {
                let hook = ClaudeCodeIntegration.hookExecutablePath ?? "dreamux-hook"
                try installer.install(
                    harnessID: harness.id,
                    configURL: url,
                    hookCommand: "\(hook) event --harness \(harness.id)"
                )
            }
        } catch HarnessConfigInstaller.InstallError.unreadableConfig {
            // Refuse rather than rewrite a file we cannot parse.
            errors[harness.id] = "Could not read ~/.cursor/hooks.json — left unchanged."
        } catch {
            errors[harness.id] = "Could not write ~/.cursor/hooks.json — left unchanged."
        }
        refresh()
    }
}
