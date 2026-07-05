import SwiftUI

/// The git chip's dropdown: this worktree's commits, newest first,
/// each opening a diff vs its parent. Styling matches the services
/// popover (HeaderRunControls) — 340pt, callout/caption, hover rows.
struct CommitTrailPopover: View {
    let worktreeURL: URL
    let branch: String
    let defaultBranch: String?
    let openDiff: (DiffRequest) -> Void

    @State private var commits: [CommitInfo] = []
    @State private var hasUncommitted = false
    @State private var loaded = false
    @State private var hoveredID: String?
    @State private var rootSHA: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if hasUncommitted {
                        uncommittedRow
                    }
                    ForEach(commits) { commit in
                        commitRow(commit)
                    }
                    if loaded && commits.isEmpty && !hasUncommitted {
                        Text("No commits yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
                .padding(8)
            }
            // Popovers size to intrinsic content and a ScrollView
            // reports essentially none — without an explicit height the
            // list collapses to a sliver under the header. Estimate
            // from the row count (two-line rows ≈ 44pt) and cap.
            .frame(height: listHeight)
        }
        .frame(width: 340)
        .task { await load() }
    }

    private var listHeight: CGFloat {
        let rows = commits.count + (hasUncommitted ? 1 : 0)
        guard loaded else { return 80 }
        guard rows > 0 else { return 56 }
        return min(360, CGFloat(rows) * 44 + 16)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(branch)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 12)
            if let base = defaultBranch, base != branch {
                Button {
                    Task {
                        let from = await GitOperations.mergeBase(
                            of: base, in: worktreeURL) ?? base
                        openDiff(DiffRequest(
                            worktreeURL: worktreeURL,
                            fromRevision: from,
                            toRevision: "HEAD",
                            title: "\(branch) vs \(base)"))
                    }
                } label: {
                    Label("Diff vs \(base)", systemImage: "plus.forwardslash.minus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Everything this branch changes relative to \(base)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var uncommittedRow: some View {
        row(
            id: "uncommitted",
            title: "Uncommitted changes",
            titleStyle: AnyShapeStyle(Color.orange),
            subtitle: "working tree vs HEAD",
            badge: nil
        ) {
            openDiff(DiffRequest(
                worktreeURL: worktreeURL,
                fromRevision: "HEAD",
                toRevision: nil,
                title: "Uncommitted changes"))
        }
    }

    private func commitRow(_ commit: CommitInfo) -> some View {
        row(
            id: commit.sha,
            title: commit.subject,
            titleStyle: AnyShapeStyle(.primary),
            subtitle: subtitleFor(commit),
            badge: commit.subject.hasPrefix("Task ") ? "checkmark.circle" : nil
        ) {
            openDiff(DiffRequest(
                worktreeURL: worktreeURL,
                fromRevision: commit.sha == rootSHA ? GitOperations.emptyTreeSHA : "\(commit.sha)^",
                toRevision: commit.sha,
                title: commit.shortSHA))
        }
        .contextMenu {
            Button("Copy SHA") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.sha, forType: .string)
            }
        }
    }

    private func subtitleFor(_ commit: CommitInfo) -> String {
        var parts = [commit.shortSHA]
        if commit.insertions > 0 || commit.deletions > 0 {
            parts.append("+\(commit.insertions) −\(commit.deletions)")
        }
        return parts.joined(separator: "  ")
    }

    private func row(
        id: String,
        title: String,
        titleStyle: AnyShapeStyle,
        subtitle: String,
        badge: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        if let badge {
                            Image(systemName: badge)
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                                .help("Task commit")
                        }
                        Text(title)
                            .font(.callout)
                            .foregroundStyle(titleStyle)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Text(subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if hoveredID == id {
                    Image(systemName: "plus.forwardslash.minus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .help("View diff")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hoveredID == id ? Color.primary.opacity(0.06) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredID = id }
            else if hoveredID == id { hoveredID = nil }
        }
    }

    private func load() async {
        hasUncommitted = await GitOperations.hasUncommittedChanges(in: worktreeURL)
        // rootSHA must land before commits: a row renders as soon as
        // `commits` is set, and until rootSHA is known its tap would
        // build the root commit's invalid `sha^` revspec.
        rootSHA = await GitOperations.rootCommitSHA(in: worktreeURL)
        commits = await GitOperations.commitLog(
            in: worktreeURL, baseBranch: defaultBranch)
        loaded = true
    }
}
