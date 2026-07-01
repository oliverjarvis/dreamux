import SwiftUI

struct AddFeatureSheet: View {
    let projectName: String
    let availableRepos: [Repository]
    let onSubmit: (_ name: String, _ repoIDs: [String]) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var selected: Set<String>

    @FocusState private var isNameFocused: Bool

    init(
        projectName: String,
        availableRepos: [Repository],
        onSubmit: @escaping (_ name: String, _ repoIDs: [String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.projectName = projectName
        self.availableRepos = availableRepos
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        // Default: all repos selected — most agentic features touch
        // every codebase in the project. User unchecks for narrower
        // single-repo work.
        _selected = State(initialValue: Set(availableRepos.map(\.name)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Feature")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("e.g. add-login", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit(submitIfReady)
                Text("Becomes the git branch name and the directory under \(projectName)/features/. A worktree on that branch is created in each selected repo.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Repositories")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if availableRepos.isEmpty {
                    Text("No repositories yet — add one before creating a feature.")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(availableRepos) { repo in
                            Toggle(isOn: binding(for: repo.name)) {
                                HStack(spacing: 8) {
                                    Image(systemName: "shippingbox.fill")
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: 12))
                                    Text(repo.name)
                                        .font(.callout)
                                    Text(repo.defaultBranch)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: submitIfReady)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { isNameFocused = true }
    }

    private func binding(for repoName: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(repoName) },
            set: { isOn in
                if isOn { selected.insert(repoName) } else { selected.remove(repoName) }
            }
        )
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedName.isEmpty && !selected.isEmpty
    }

    private func submitIfReady() {
        guard canSubmit else { return }
        // Preserve original repo ordering from `availableRepos` so the
        // sidebar chips are stable.
        let orderedSelected = availableRepos.map(\.name).filter { selected.contains($0) }
        onSubmit(trimmedName, orderedSelected)
    }
}
