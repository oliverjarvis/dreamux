import SwiftUI

/// The "Open branch…" picker: search, one row per branch across the
/// project's repos, a badge saying where that branch lives, and an
/// inline note when the background `origin` fetch didn't get through.
///
/// It owns NO git logic — `loadLocal` and `refresh` are injected, so the
/// sheet renders in tests without a repository, and the sidebar keeps the
/// single place that talks to `GitOperations`. Opening the sheet IS the
/// refresh, so there is deliberately no refresh button
/// (CLAUDE.md: drop controls an automatic mechanism makes redundant).
struct BranchOpenSheet: View {
    /// One catalog read: the candidates, plus whether the `origin` fetch
    /// behind them failed.
    struct Catalog: Equatable {
        var candidates: [BranchCandidate]
        var fetchFailed: Bool
        static let empty = Catalog(candidates: [], fetchFailed: false)
    }

    static let title = "Open Branch"
    /// Never an alert: the list still works from local refs.
    static let fetchFailedNote = "Couldn't reach origin — showing last-known branches."
    static let refreshingNote = "Updating from origin…"
    static let noRepositoriesMessage = "Add a repository before opening a branch."
    static let localBadge = "local"
    static let remoteBadge = "origin"
    static let openBadge = "Open"
    static let openButtonTitle = "Open"
    static let activateButtonTitle = "Activate"

    /// Names the repo(s) instead of rendering a blank list.
    static func noBranchesMessage(repoNames: [String]) -> String {
        "No other branches in \(repoSummary(repoNames))."
    }

    /// `a · b · c`, and `a · b · +2` past three — the same shape as the
    /// sidebar's `repoSubtitle`, so a workspace reads identically before
    /// and after it is opened.
    static func repoSummary(_ names: [String]) -> String {
        if names.count <= 3 { return names.joined(separator: " · ") }
        return names.prefix(2).joined(separator: " · ") + " · +\(names.count - 2)"
    }

    let repoNames: [String]
    /// Local refs only — returns before any network call, because bare
    /// clones already carry `refs/remotes/origin/*`.
    let loadLocal: () async -> Catalog
    /// Fetch `origin` in every repo, then re-list.
    let refresh: () async -> Catalog
    let onSubmit: (BranchCandidate) -> Void
    let onCancel: () -> Void

    @State private var catalog: Catalog = .empty
    @State private var query = ""
    /// Selection is held by branch NAME, so the highlighted row survives
    /// the swap when the background fetch's re-list lands.
    @State private var selection: String?
    @State private var isRefreshing = false
    @FocusState private var searchFocused: Bool

    private var visible: [BranchCandidate] {
        BranchCatalog.filtered(catalog.candidates, query: query)
    }

    private var selected: BranchCandidate? {
        visible.first { $0.name == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Self.title)
                .font(.title3.weight(.semibold))

            TextField("Search branches", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)

            Divider()

            list

            if catalog.fetchFailed {
                note(Self.fetchFailedNote)
            } else if isRefreshing {
                note(Self.refreshingNote)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(selected?.isOpen == true
                       ? Self.activateButtonTitle : Self.openButtonTitle) {
                    if let selected { onSubmit(selected) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .task { await load() }
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private var list: some View {
        if repoNames.isEmpty {
            emptyState(Self.noRepositoriesMessage)
        } else if catalog.candidates.isEmpty {
            emptyState(Self.noBranchesMessage(repoNames: repoNames))
        } else if visible.isEmpty {
            emptyState("No branch matches “\(query)”.")
        } else {
            let now = Date()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visible) { candidate in
                        row(candidate, now: now)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Name on top at 15pt with its badge; repos, age, author and commit
    /// subject on a 12pt secondary line beneath — generous, not dense.
    private func row(_ candidate: BranchCandidate, now: Date) -> some View {
        let isSelected = candidate.name == selection
        return Button { selection = candidate.name } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(candidate.name)
                        .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(badge(for: candidate))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(subtitle(for: candidate, now: now))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
    }

    private func badge(for candidate: BranchCandidate) -> String {
        if candidate.isOpen { return Self.openBadge }
        return candidate.isRemoteOnly ? Self.remoteBadge : Self.localBadge
    }

    private func subtitle(for candidate: BranchCandidate, now: Date) -> String {
        [
            Self.repoSummary(candidate.repos),
            BranchCatalog.age(of: candidate.committedAt, now: now),
            candidate.author,
            candidate.subject,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
    }

    /// Two things happen at once when the sheet opens: local refs render
    /// immediately, and a fetch runs behind them. When the fetch settles
    /// the list is replaced in place — selection is by name, so the
    /// highlighted row is preserved across the swap.
    private func load() async {
        catalog = await loadLocal()
        isRefreshing = true
        catalog = await refresh()
        isRefreshing = false
        if let selection, !catalog.candidates.contains(where: { $0.name == selection }) {
            self.selection = nil
        }
    }
}
