import XCTest
@testable import Dreamux

/// Maps a task's heading to the commit range that implemented it.
/// Subjects match when they start with the task title (the agent
/// commits the heading verbatim; the backstop appends " (auto)").
final class TaskDiffResolverTests: XCTestCase {
    private func commit(_ sha: String, _ subject: String) -> CommitInfo {
        CommitInfo(sha: sha, shortSHA: String(sha.prefix(7)),
                   subject: subject, authorDate: nil,
                   insertions: 0, deletions: 0)
    }

    /// Single matching commit → parent..commit.
    func testSingleCommit() {
        let log = [commit(String(repeating: "b", count: 40), "Other work"),
                   commit(String(repeating: "a", count: 40), "Task 2: Wire the store")]
        let range = TaskDiffResolver.range(for: "Task 2: Wire the store", in: log)
        XCTAssertEqual(range?.from, String(repeating: "a", count: 40) + "^")
        XCTAssertEqual(range?.to, String(repeating: "a", count: 40))
    }

    /// Several commits (agent commit + backstop " (auto)") → span from
    /// the OLDEST match's parent to the NEWEST match. Log is
    /// newest-first.
    func testMultipleCommitsSpan() {
        let newest = String(repeating: "c", count: 40)
        let oldest = String(repeating: "a", count: 40)
        let log = [commit(newest, "Task 2: Wire the store (auto)"),
                   commit(String(repeating: "b", count: 40), "Unrelated"),
                   commit(oldest, "Task 2: Wire the store")]
        let range = TaskDiffResolver.range(for: "Task 2: Wire the store", in: log)
        XCTAssertEqual(range?.from, oldest + "^")
        XCTAssertEqual(range?.to, newest)
    }

    /// Prefix discipline: "Task 2: Wire" must not match
    /// "Task 2: Wire the store"'s search and vice versa — matching is
    /// title-then-boundary (exact title, or title followed by " (").
    func testNoFalsePrefixMatches() {
        let log = [commit(String(repeating: "a", count: 40), "Task 21: Wireless")]
        XCTAssertNil(TaskDiffResolver.range(for: "Task 2: Wire", in: log))
        XCTAssertNil(TaskDiffResolver.range(for: "Task 21: Wireless extras", in: log))
    }

    func testNoMatchesReturnsNil() {
        XCTAssertNil(TaskDiffResolver.range(for: "Task 9: Ghost", in: []))
    }
}
