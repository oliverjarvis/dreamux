import SwiftUI

/// Two paths to a new project applet: **Create** a fresh one (name +
/// description → scaffold + builder agent) or **Adopt** an existing library
/// applet. `onAdopt` is optional so App Studio (Task 9) can reuse this sheet
/// create-only — nil hides the Adopt path entirely.
struct NewAppSheet: View {
    let library: [Applet]                   // appLibrary.applets (refreshed on appear by caller)
    let onCreate: (String, String) -> Void  // (name, description)
    let onAdopt: ((Applet) -> Void)?
    let onCancel: () -> Void

    @State private var name = ""
    @State private var description = ""
    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New App")
                .font(.title3.weight(.semibold))
            Text("Scaffold a small, buildless web tool that runs inside Dreamux. A builder agent opens in a terminal and starts from your description; the preview hot-reloads as it saves.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("My Tool", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(submitCreate)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $description)
                    .font(.body)
                    .frame(height: 72)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.12)))
            }

            if let onAdopt, !library.isEmpty {
                Divider()
                Text("Adopt from App Studio")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(library) { applet in
                            libraryRow(applet, onAdopt: onAdopt)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Create", action: submitCreate)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { nameFocused = true }
    }

    private func submitCreate() {
        guard !trimmedName.isEmpty else { return }
        onCreate(trimmedName, description.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func libraryRow(_ applet: Applet, onAdopt: @escaping (Applet) -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: applet.manifest.icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(applet.manifest.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1).truncationMode(.tail)
                if !applet.manifest.description.isEmpty {
                    Text(applet.manifest.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            Button("Adopt") { onAdopt(applet) }
                .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}
