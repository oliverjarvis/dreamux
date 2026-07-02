import XCTest
@testable import Dreamux

/// Integration tests for `FeatureProvisioner` using real git repos in a
/// per-test `TestSandbox`: real worktrees, real symlinks, no mocks. The
/// provisioner's on-disk shape —
///
///     repos/<repo>/<feature>/      (worktree, branch == feature name)
///     features/<feature>/<repo>    (symlink → ../../repos/<repo>/<feature>)
///
/// — is what tabs cd into and what launch-time rediscovery scans, so
/// these tests pin both the happy path and the rollback/repair edges.
@MainActor
final class FeatureProvisionerTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!

    /// The async setUp/tearDown variants are the ones that may carry the
    /// class's @MainActor isolation, which the stored properties need.
    override func setUp() async throws {
        // initBare makes a starter commit internally with no way to pass
        // `-c user.*`; exporting the GIT_* identity keeps fixture setup
        // working on machines with no global git identity (runGit
        // snapshots the process environment per invocation).
        setenv("GIT_AUTHOR_NAME", "Dreamux Tests", 1)
        setenv("GIT_AUTHOR_EMAIL", "tests@dreamux.local", 1)
        setenv("GIT_COMMITTER_NAME", "Dreamux Tests", 1)
        setenv("GIT_COMMITTER_EMAIL", "tests@dreamux.local", 1)

        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "proj")
    }

    override func tearDown() async throws {
        sandbox?.destroy()
        sandbox = nil
        project = nil
    }

    // MARK: - provision

    func testProvisionAcrossTwoReposCreatesWorktreesSymlinksAndReadme() async throws {
        let (alpha, beta) = try await makeTwoRepos()

        let featureDir = try await FeatureProvisioner.provision(
            featureName: "feature-x", in: project, across: [alpha, beta]
        )
        XCTAssertEqual(
            featureDir.path,
            FeatureProvisioner.featureDirectory(in: project, name: "feature-x").path
        )

        for repo in [alpha, beta] {
            // Worktree per repo, checked out on a branch named after the
            // feature.
            let worktree = repo.rootURL.appendingPathComponent("feature-x", isDirectory: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
            let head = try await git(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree)
            XCTAssertEqual(head, "feature-x")

            // The aggregation entry must be a *relative* symlink so the
            // project folder stays movable.
            let link = featureDir.appendingPathComponent(repo.name)
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                "../../repos/\(repo.name)/feature-x"
            )
        }

        // Reading a fixture file *through* the symlink proves the
        // relative target actually resolves from features/<name>/.
        let throughLink = featureDir.appendingPathComponent("alpha/alpha.txt")
        XCTAssertEqual(try String(contentsOf: throughLink, encoding: .utf8), "a\n")

        let readme = try String(
            contentsOf: featureDir.appendingPathComponent("DREAMUX.md"), encoding: .utf8
        )
        XCTAssertTrue(readme.contains("feature-x"), "DREAMUX.md must describe this feature")
    }

    func testProvisionDuplicateFeatureNameFailsWithoutDamage() async throws {
        let (alpha, beta) = try await makeTwoRepos()
        let featureDir = try await FeatureProvisioner.provision(
            featureName: "feature-x", in: project, across: [alpha, beta]
        )
        let tipBefore = try await git(["rev-parse", "refs/heads/feature-x"], in: alpha.rootURL)

        do {
            _ = try await FeatureProvisioner.provision(
                featureName: "feature-x", in: project, across: [alpha, beta]
            )
            XCTFail("expected FeatureError.alreadyExists")
        } catch FeatureError.alreadyExists(let name) {
            XCTAssertEqual(name, "feature-x")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // The failed attempt must neither roll back nor mangle the
        // original provision — same worktrees, same symlinks, same tips.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: featureDir.appendingPathComponent("DREAMUX.md").path
        ))
        for repo in [alpha, beta] {
            let worktree = repo.rootURL.appendingPathComponent("feature-x", isDirectory: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: featureDir.appendingPathComponent(repo.name).path
                ),
                "../../repos/\(repo.name)/feature-x"
            )
        }
        let tipAfter = try await git(["rev-parse", "refs/heads/feature-x"], in: alpha.rootURL)
        XCTAssertEqual(tipAfter, tipBefore)
    }

    func testProvisionRollsBackWhenAWorktreeCollides() async throws {
        let (alpha, beta) = try await makeTwoRepos()
        // Occupy the worktree slot in the *second* repo without any
        // feature dir, so provision succeeds for alpha and then fails on
        // beta — the rollback path that "no half-provisioned debris"
        // promises to clean up.
        try await GitOperations.addWorktree(in: beta.rootURL, branch: "feature-y")

        do {
            _ = try await FeatureProvisioner.provision(
                featureName: "feature-y", in: project, across: [alpha, beta]
            )
            XCTFail("expected provision to fail on the colliding worktree")
        } catch {
            // The specific error (a GitError) doesn't matter; the
            // rollback below does.
        }

        let featureDir = FeatureProvisioner.featureDirectory(in: project, name: "feature-y")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: featureDir.path),
            "aggregation dir must be rolled back"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: alpha.rootURL.appendingPathComponent("feature-y").path
        ), "alpha's freshly provisioned worktree must be rolled back")
        let alphaBranchSurvives = await branchExists("feature-y", in: alpha.rootURL)
        XCTAssertFalse(alphaBranchSurvives, "alpha's freshly created branch must be rolled back")
        // The colliding worktree wasn't ours to create, so it must not
        // be ours to destroy.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: beta.rootURL.appendingPathComponent("feature-y").path
        ))
    }

    func testProvisionWithEmptyRepoListThrowsNoRepositories() async throws {
        do {
            _ = try await FeatureProvisioner.provision(
                featureName: "feature-z", in: project, across: []
            )
            XCTFail("expected FeatureError.noRepositories")
        } catch FeatureError.noRepositories {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // The guard fires before any directory is created — not even the
        // top-level features/ folder should appear.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: FeatureProvisioner.featuresDirectory(for: project).path
        ))
    }

    // MARK: - docs symlink

    func testProvisionLinksProjectDocsIntoAggregationDir() async throws {
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "api", files: ["api.txt": "a\n"]
        )
        let dir = try await FeatureProvisioner.provision(
            featureName: "docs-link", in: project, across: [repo])

        let link = dir.appendingPathComponent("docs")
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertEqual(dest, "../../docs")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.rootPath.appendingPathComponent("docs/plans").path,
            isDirectory: &isDir) && isDir.boolValue,
            "provision ensures the docs home exists")

        let readme = try String(
            contentsOf: dir.appendingPathComponent("DREAMUX.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("docs/specs/"))
        XCTAssertTrue(readme.contains("docs/plans/"))
    }

    func testDocsSymlinkRenamedWhenRepoNamedDocs() async throws {
        let repo = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "docs", files: ["docs.txt": "a\n"]
        )
        let dir = try await FeatureProvisioner.provision(
            featureName: "collide", in: project, across: [repo])
        let dest = try FileManager.default.destinationOfSymbolicLink(
            atPath: dir.appendingPathComponent("project-docs").path)
        XCTAssertEqual(dest, "../../docs")
        // The repo's own symlink keeps its name.
        let repoDest = try FileManager.default.destinationOfSymbolicLink(
            atPath: dir.appendingPathComponent("docs").path)
        XCTAssertEqual(repoDest, "../../repos/docs/collide")
    }

    // MARK: - ensureFeatureDirectory

    func testEnsureFeatureDirectoryRestoresAndRepairsLinks() async throws {
        let (alpha, beta) = try await makeTwoRepos()
        let featureDir = try await FeatureProvisioner.provision(
            featureName: "feature-x", in: project, across: [alpha, beta]
        )
        let fm = FileManager.default
        let alphaLink = featureDir.appendingPathComponent("alpha")
        let betaLink = featureDir.appendingPathComponent("beta")
        let readme = featureDir.appendingPathComponent("DREAMUX.md")

        // Simulate user damage: one link and the README deleted, the
        // other link retargeted at the wrong place.
        try fm.removeItem(at: alphaLink)
        try fm.removeItem(at: readme)
        try fm.removeItem(at: betaLink)
        try fm.createSymbolicLink(
            atPath: betaLink.path,
            withDestinationPath: "../../repos/beta/not-the-worktree"
        )

        _ = await FeatureProvisioner.ensureFeatureDirectory(
            featureName: "feature-x", in: project, across: [alpha, beta]
        )

        XCTAssertEqual(
            try fm.destinationOfSymbolicLink(atPath: alphaLink.path),
            "../../repos/alpha/feature-x",
            "deleted symlink must be restored"
        )
        XCTAssertEqual(
            try fm.destinationOfSymbolicLink(atPath: betaLink.path),
            "../../repos/beta/feature-x",
            "wrong-target symlink must be replaced"
        )
        XCTAssertTrue(fm.fileExists(atPath: readme.path), "DREAMUX.md must be rewritten")
    }

    // MARK: - teardown

    func testTeardownRemovesEverythingAndIsSafeToRepeat() async throws {
        let (alpha, beta) = try await makeTwoRepos()
        let featureDir = try await FeatureProvisioner.provision(
            featureName: "feature-x", in: project, across: [alpha, beta]
        )

        await FeatureProvisioner.teardown(
            featureName: "feature-x", in: project, across: [alpha, beta]
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: featureDir.path))
        for repo in [alpha, beta] {
            let worktree = repo.rootURL.appendingPathComponent("feature-x", isDirectory: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
            let branchSurvives = await branchExists("feature-x", in: repo.rootURL)
            XCTAssertFalse(branchSurvives, "feature branch must be deleted in \(repo.name)")
            let list = try await git(["worktree", "list", "--porcelain"], in: repo.rootURL)
            XCTAssertFalse(list.contains("feature-x"), "worktree list must be pruned in \(repo.name)")
        }

        // Teardown is documented best-effort — running it again over an
        // already-gone feature must not blow up or resurrect anything.
        await FeatureProvisioner.teardown(
            featureName: "feature-x", in: project, across: [alpha, beta]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: featureDir.path))
    }

    // MARK: - Helpers

    /// Two independent bare-layout repos, each with one distinct fixture
    /// file so tests can tell content apart through symlinks.
    private func makeTwoRepos() async throws -> (alpha: Repository, beta: Repository) {
        let alpha = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "alpha", files: ["alpha.txt": "a\n"]
        )
        let beta = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "beta", files: ["beta.txt": "b\n"]
        )
        return (alpha, beta)
    }

    /// Run git via the app's own plumbing and trim the trailing newline
    /// so assertions can compare bare values.
    private func git(_ args: [String], in cwd: URL) async throws -> String {
        try await GitOperations.runGit(args, in: cwd)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when `refs/heads/<branch>` resolves — exit status is the
    /// answer, so a thrown `commandFailed` means "no such branch".
    private func branchExists(_ branch: String, in repoRoot: URL) async -> Bool {
        (try? await GitOperations.runGit(
            ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"],
            in: repoRoot
        )) != nil
    }
}
