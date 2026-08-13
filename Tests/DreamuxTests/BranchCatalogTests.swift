import XCTest
@testable import Dreamux

/// The pure layer behind "Open branch…": `for-each-ref` text in,
/// deduplicated and ranked candidates out. Table-tested without git, in
/// the spirit of `AdHocWorkspacesTests` and `PlanWorkspacePresenceTests`.
final class BranchCatalogTests: XCTestCase {

    // MARK: - parse

    func testParseReadsEveryFieldAndStripsRefPrefixes() {
        let output = """
        refs/heads/fix/retry\t1750000000\talice\tabc1234\tRetry on 429
        refs/remotes/origin/spike-dagre\t1749000000\tollie\tdef5678\tTry dagre port
        """

        let refs = BranchCatalog.parse(output)

        XCTAssertEqual(refs.count, 2)
        XCTAssertEqual(refs[0], BranchRef(
            name: "fix/retry", isRemote: false,
            committedAt: Date(timeIntervalSince1970: 1_750_000_000),
            author: "alice", sha: "abc1234", subject: "Retry on 429"))
        XCTAssertEqual(refs[1].name, "spike-dagre")
        XCTAssertTrue(refs[1].isRemote)
        XCTAssertEqual(refs[1].author, "ollie")
    }

    func testParseKeepsATabInsideTheSubject() {
        // The subject is the last field precisely so this is harmless.
        let refs = BranchCatalog.parse("refs/heads/x\t1\talice\tabc1234\tone\ttwo")
        XCTAssertEqual(refs.first?.subject, "one\ttwo")
    }

    func testParseDiscardsOriginHEADForeignRefsAndMalformedLines() {
        let refs = BranchCatalog.parse("""
        refs/remotes/origin/HEAD\t1750000000\talice\tabc1234\t
        refs/tags/v1\t1750000000\talice\tabc1234\tTagged
        refs/heads/bad-date\tnot-a-number\talice\tabc1234\tBroken
        short\tline
        refs/heads/keep\t1750000000\talice\tabc1234\tKeep me
        """)

        XCTAssertEqual(refs.map(\.name), ["keep"])
    }

    // MARK: - candidates

    func testLocalAndRemoteRefsOfTheSameNameFoldIntoOneCandidate() {
        let result = BranchCatalog.candidates(
            perRepo: [(repo: "dreamux", defaultBranch: "main", refs: [
                ref("fix/retry", at: 100),
                ref("fix/retry", remote: true, at: 90),
            ])],
            openWorkspaceNames: [])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].repos, ["dreamux"])
        XCTAssertTrue(result[0].startPoints.isEmpty, "a local head opens from itself")
        XCTAssertFalse(result[0].isRemoteOnly)
    }

    func testARemoteOnlyRefContributesAStartPointAndTheOriginBadge() {
        let result = BranchCatalog.candidates(
            perRepo: [(repo: "dreamux", defaultBranch: "main", refs: [
                ref("fix/retry", remote: true, at: 100),
            ])],
            openWorkspaceNames: [])

        XCTAssertEqual(result[0].startPoints, ["dreamux": "origin/fix/retry"])
        XCTAssertTrue(result[0].isRemoteOnly)
    }

    func testRemoteOnlyInAnyRepoIsEnoughToReadAsOrigin() {
        let result = BranchCatalog.candidates(
            perRepo: [
                (repo: "alpha", defaultBranch: "main", refs: [ref("shared", at: 100)]),
                (repo: "beta", defaultBranch: "main", refs: [ref("shared", remote: true, at: 90)]),
            ],
            openWorkspaceNames: [])

        XCTAssertEqual(result[0].repos, ["alpha", "beta"])
        XCTAssertEqual(result[0].startPoints, ["beta": "origin/shared"],
                       "only the repo lacking a local head needs a start point")
        XCTAssertTrue(result[0].isRemoteOnly)
    }

    func testDefaultBranchIsDroppedPerRepoAndCanRemoveACandidateEntirely() {
        let result = BranchCatalog.candidates(
            perRepo: [
                (repo: "alpha", defaultBranch: "main", refs: [
                    ref("main", at: 200), ref("shared", at: 100),
                ]),
                // `shared` IS beta's default branch — that's beta's `main`
                // workspace, so beta contributes nothing for it.
                (repo: "beta", defaultBranch: "shared", refs: [ref("shared", at: 150)]),
            ],
            openWorkspaceNames: [])

        XCTAssertEqual(result.map(\.name), ["shared"])
        XCTAssertEqual(result[0].repos, ["alpha"])
    }

    func testACandidateThatIsOnlyEverADefaultBranchDisappears() {
        let result = BranchCatalog.candidates(
            perRepo: [(repo: "alpha", defaultBranch: "main", refs: [
                ref("main", at: 100), ref("main", remote: true, at: 100),
            ])],
            openWorkspaceNames: [])

        XCTAssertTrue(result.isEmpty)
    }

    func testDotPrefixedNamesAreDropped() {
        // They would collide with `.bare` / `.git` inside the repo root.
        let result = BranchCatalog.candidates(
            perRepo: [(repo: "alpha", defaultBranch: "main", refs: [
                ref(".hidden", at: 100), ref("visible", at: 90),
            ])],
            openWorkspaceNames: [])

        XCTAssertEqual(result.map(\.name), ["visible"])
    }

    func testIsOpenComesFromTheOpenWorkspaceNames() {
        let result = BranchCatalog.candidates(
            perRepo: [(repo: "alpha", defaultBranch: "main", refs: [
                ref("flows-canvas", at: 200), ref("spike", at: 100),
            ])],
            openWorkspaceNames: ["flows-canvas"])

        XCTAssertEqual(result[0].name, "flows-canvas")
        XCTAssertTrue(result[0].isOpen)
        XCTAssertFalse(result[1].isOpen)
    }

    func testCandidatesAreOrderedNewestCommitFirst() {
        let result = BranchCatalog.candidates(
            perRepo: [(repo: "alpha", defaultBranch: "main", refs: [
                ref("old", at: 100), ref("newest", at: 300), ref("middle", at: 200),
            ])],
            openWorkspaceNames: [])

        XCTAssertEqual(result.map(\.name), ["newest", "middle", "old"])
    }

    func testMultiRepoUnionTakesTheNewestCommitsAuthorAndSubject() {
        let result = BranchCatalog.candidates(
            perRepo: [
                (repo: "alpha", defaultBranch: "main", refs: [
                    ref("shared", at: 100, author: "alice", subject: "Older"),
                ]),
                (repo: "beta", defaultBranch: "main", refs: [
                    ref("shared", at: 200, author: "ollie", subject: "Newer"),
                ]),
            ],
            openWorkspaceNames: [])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].repos, ["alpha", "beta"], "repos stay in project order")
        XCTAssertEqual(result[0].author, "ollie")
        XCTAssertEqual(result[0].subject, "Newer")
        XCTAssertEqual(result[0].committedAt, Date(timeIntervalSince1970: 200))
    }

    // MARK: - filtered

    func testEmptyQueryPassesTheListThroughUntouched() {
        let all = [candidate("b", at: 200), candidate("a", at: 100)]
        XCTAssertEqual(BranchCatalog.filtered(all, query: "  ").map(\.name), ["b", "a"])
    }

    func testQueryRanksByFuzzyScoreAndDropsNonMatches() {
        let all = [
            candidate("fix/retry-backoff", at: 300),
            candidate("retry-later", at: 100),
            candidate("unrelated", at: 200),
        ]

        let hits = BranchCatalog.filtered(all, query: "retry")

        // A prefix match outranks a mid-string one even though it is
        // older, and a name that isn't a subsequence match is gone.
        XCTAssertEqual(hits.map(\.name), ["retry-later", "fix/retry-backoff"])
    }

    // MARK: - age

    func testAgeRendersCompactlyForTheRowsMetadataLine() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        func ago(_ seconds: TimeInterval) -> String {
            BranchCatalog.age(of: now.addingTimeInterval(-seconds), now: now)
        }
        XCTAssertEqual(ago(10), "just now")
        XCTAssertEqual(ago(5 * 60), "5m ago")
        XCTAssertEqual(ago(2 * 3600), "2h ago")
        XCTAssertEqual(ago(3 * 86400), "3d ago")
        XCTAssertEqual(ago(7 * 86400), "1w ago")
        XCTAssertEqual(ago(400 * 86400), "1y ago")
        XCTAssertEqual(ago(-60), "just now", "a clock skew must not print a negative age")
    }

    // MARK: - Helpers

    private func ref(
        _ name: String, remote: Bool = false, at unix: TimeInterval,
        author: String = "alice", subject: String = "Work"
    ) -> BranchRef {
        BranchRef(name: name, isRemote: remote,
                  committedAt: Date(timeIntervalSince1970: unix),
                  author: author, sha: "abc1234", subject: subject)
    }

    private func candidate(_ name: String, at unix: TimeInterval) -> BranchCandidate {
        BranchCandidate(
            name: name, repos: ["alpha"], startPoints: [:], isRemoteOnly: false,
            committedAt: Date(timeIntervalSince1970: unix),
            author: "alice", subject: "Work", isOpen: false)
    }
}
