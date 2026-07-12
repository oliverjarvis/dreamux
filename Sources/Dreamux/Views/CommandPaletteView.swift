import SwiftUI

/// The ⌘K palette: a centered panel, fuzzy-searching projects,
/// workspaces & plans, commands, and file names. Pure presentation — all
/// data and actions arrive through `PaletteModel`; executing any row
/// calls `onDismiss` after the action runs.
struct CommandPaletteView: View {
    @Bindable var model: PaletteModel
    let onDismiss: () -> Void

    @FocusState private var queryFocused: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Invisible hit target spanning the full window so a
                // click anywhere outside the panel dismisses — no
                // dimming scrim (it never reached full window height).
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                panel
                    .frame(width: 600)
                    .padding(.top, geo.size.height * 0.18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            queryFocused = true
            // The Ghostty terminal holds first responder aggressively; a
            // next-runloop retry wins the race on the first open.
            DispatchQueue.main.async { queryFocused = true }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search projects, plans, files…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($queryFocused)
                    .onKeyPress(.downArrow) {
                        model.moveSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        model.moveSelection(by: -1)
                        return .handled
                    }
                    .onSubmit {
                        if model.executeSelected() { onDismiss() }
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if model.sections.isEmpty {
                Text("No results")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        results
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: model.selectedRowID) { _, rowID in
                        if let rowID { proxy.scrollTo(rowID) }
                    }
                }
            }
        }
        .panelCard(radius: 12)
        .onExitCommand(perform: onDismiss)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.sections) { section in
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.kind.title.uppercased())
                        .font(.system(size: 13, weight: .semibold))
                        .kerning(0.4)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 2)
                    ForEach(section.rows) { row in
                        rowView(row)
                    }
                }
            }
        }
        .padding(10)
    }

    private func rowView(_ row: PaletteRow) -> some View {
        let selected = row.id == model.selectedRowID
        return Button {
            model.select(row.id)
            if model.executeSelected() { onDismiss() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: row.candidate.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(highlightedTitle(row))
                    .font(.system(size: 15))
                    .lineLimit(1)
                if let subtitle = row.candidate.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(selected ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { model.select(row.id) }
        }
        .id(row.id)
    }

    /// Bold the characters the fuzzy match hit.
    private func highlightedTitle(_ row: PaletteRow) -> AttributedString {
        var attributed = AttributedString(row.candidate.title)
        let offsets = Set(row.match.matchedOffsets)
        for (offset, index) in attributed.characters.indices.enumerated()
        where offsets.contains(offset) {
            let next = attributed.characters.index(after: index)
            attributed[index..<next].font = .system(size: 15, weight: .bold)
        }
        return attributed
    }
}
