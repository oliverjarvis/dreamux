import Foundation

/// One git ref as `for-each-ref` reported it, with the `refs/…` prefix
/// stripped and its origin recorded.
struct BranchRef: Equatable {
    /// "fix/retry" — the ref name with `refs/heads/` or
    /// `refs/remotes/origin/` removed.
    let name: String
    /// Came from `refs/remotes/origin/`.
    let isRemote: Bool
    let committedAt: Date
    let author: String
    let sha: String
    let subject: String
}

/// One openable branch, folded across every repo in the project.
struct BranchCandidate: Identifiable, Equatable {
    var id: String { name }
    let name: String
    /// Repos that have this branch, in project order.
    let repos: [String]
    /// Repo name → start point, present only where the branch exists on
    /// `origin` and has no local head. Feeds `addWorktree(startPoint:)`.
    let startPoints: [String: String]
    /// True when at least one repo has only the remote ref — so a branch
    /// that is remote-only anywhere reads as `origin` in the picker.
    let isRemoteOnly: Bool
    /// Newest commit across the repos holding this branch…
    let committedAt: Date
    /// …and that commit's author and subject.
    let author: String
    let subject: String
    /// A workspace already exists for this branch, so the sheet offers
    /// "Activate" instead of provisioning it again.
    let isOpen: Bool
}

/// The pure decision layer behind "Open branch…": raw `for-each-ref`
/// text in, deduplicated and ranked candidates out. No IO, no SwiftUI,
/// not `@MainActor` — in the spirit of `WorkspaceWorktrees` and
/// `AdHocWorkspaces`.
enum BranchCatalog {
    private static let localPrefix = "refs/heads/"
    private static let remotePrefix = "refs/remotes/origin/"

    /// Parse `GitOperations.branchRefFormat` output. Anything that isn't
    /// a local head or an origin remote-tracking ref — tags, `origin/HEAD`,
    /// a truncated or malformed line — is dropped rather than guessed at.
    static func parse(_ forEachRefOutput: String) -> [BranchRef] {
        forEachRefOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let fields = String(line).components(separatedBy: "\t")
                guard fields.count >= 5,
                      let timestamp = TimeInterval(fields[1])
                else { return nil }

                let refname = fields[0]
                let name: String
                let isRemote: Bool
                if refname.hasPrefix(localPrefix) {
                    name = String(refname.dropFirst(localPrefix.count))
                    isRemote = false
                } else if refname.hasPrefix(remotePrefix) {
                    name = String(refname.dropFirst(remotePrefix.count))
                    isRemote = true
                } else {
                    return nil
                }
                guard !name.isEmpty, name != "HEAD" else { return nil }

                return BranchRef(
                    name: name,
                    isRemote: isRemote,
                    committedAt: Date(timeIntervalSince1970: timestamp),
                    author: fields[2],
                    sha: fields[3],
                    // The subject is last, so a tab inside it rejoins
                    // instead of shifting every field along.
                    subject: fields[4...].joined(separator: "\t")
                )
            }
    }

    /// Fold each repo's refs into one candidate per branch name, newest
    /// commit first.
    ///
    /// A repo contributes a start point only when it has the remote ref
    /// and NO local head: a repo with a local head opens from that head,
    /// which may sit behind `origin` and is deliberately left alone
    /// rather than silently fast-forwarded. A repo's own default branch
    /// is dropped from its contribution — that is the reserved `main`
    /// workspace, not a candidate.
    static func candidates(
        perRepo: [(repo: String, defaultBranch: String, refs: [BranchRef])],
        openWorkspaceNames: Set<String>
    ) -> [BranchCandidate] {
        var names: [String] = []                      // first-seen order
        var repos: [String: [String]] = [:]
        var startPoints: [String: [String: String]] = [:]
        var remoteOnly: Set<String> = []
        var newest: [String: BranchRef] = [:]

        for entry in perRepo {
            let localNames = Set(entry.refs.filter { !$0.isRemote }.map(\.name))
            var contributed: Set<String> = []

            for ref in entry.refs {
                let name = ref.name
                guard name != entry.defaultBranch else { continue }
                // A branch called `.foo` would collide with `.bare`/`.git`
                // inside the repo root.
                guard !name.hasPrefix(".") else { continue }

                if let best = newest[name] {
                    if ref.committedAt > best.committedAt { newest[name] = ref }
                } else {
                    newest[name] = ref
                    names.append(name)
                }

                guard !contributed.contains(name) else { continue }
                contributed.insert(name)
                repos[name, default: []].append(entry.repo)
                if !localNames.contains(name) {
                    startPoints[name, default: [:]][entry.repo] = "origin/\(name)"
                    remoteOnly.insert(name)
                }
            }
        }

        return names.compactMap { name -> BranchCandidate? in
            guard let ref = newest[name] else { return nil }
            return BranchCandidate(
                name: name,
                repos: repos[name] ?? [],
                startPoints: startPoints[name] ?? [:],
                isRemoteOnly: remoteOnly.contains(name),
                committedAt: ref.committedAt,
                author: ref.author,
                subject: ref.subject,
                isOpen: openWorkspaceNames.contains(name))
        }
        .sorted { lhs, rhs in
            lhs.committedAt == rhs.committedAt
                ? lhs.name < rhs.name
                : lhs.committedAt > rhs.committedAt
        }
    }

    /// Empty query → the recency order `candidates` already produced.
    /// Otherwise `FuzzyMatcher` against the branch name, best score
    /// first, non-matches dropped — the same matcher every palette
    /// provider uses.
    static func filtered(
        _ candidates: [BranchCandidate], query: String
    ) -> [BranchCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return candidates }
        return candidates
            .compactMap { candidate -> (candidate: BranchCandidate, score: Int)? in
                guard let match = FuzzyMatcher.match(trimmed, in: candidate.name)
                else { return nil }
                return (candidate, match.score)
            }
            .sorted { lhs, rhs in
                lhs.score == rhs.score
                    ? lhs.candidate.committedAt > rhs.candidate.committedAt
                    : lhs.score > rhs.score
            }
            .map(\.candidate)
    }

    /// Compact commit age for a row's metadata line — "5m ago", "2h ago",
    /// "3d ago", "1w ago". Takes `now` so it is table-tested, and clamps
    /// a future date (clock skew between machines) to "just now".
    static func age(of date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 7 { return "\(days)d ago" }
        let weeks = days / 7
        if weeks < 52 { return "\(weeks)w ago" }
        return "\(days / 365)y ago"
    }
}
