import XCTest
@testable import Dreamux

/// SwiftUI re-exports DeveloperToolsSupport, whose LibraryItem collides
/// with ours in the test target's lookup (not inside the module itself).
private typealias LibraryItem = Dreamux.LibraryItem

/// Context cards on the Context & MCPs page: the context-kind id/kind
/// semantics on `LibraryItem` (this task) and the pure `LibraryContext`
/// mapping enum (next task).
final class LibraryContextTests: XCTestCase {
    private func makeItem(
        kind: LibraryItemKind, name: String, path: String
    ) -> LibraryItem {
        LibraryItem(
            kind: kind, name: name, description: "", scopeLabel: "Project",
            path: URL(fileURLWithPath: path), accessible: true,
            accessReason: "", detail: [])
    }

    func testContextKindsAreFlagged() {
        XCTAssertTrue(LibraryItemKind.plan.isContext)
        XCTAssertTrue(LibraryItemKind.spec.isContext)
        XCTAssertTrue(LibraryItemKind.configFile.isContext)
        XCTAssertFalse(LibraryItemKind.skill.isContext)
        XCTAssertFalse(LibraryItemKind.mcpServer.isContext)
        XCTAssertFalse(LibraryItemKind.plugin.isContext)
    }

    func testContextIDsKeyByPathSoSameTitleDocsStayDistinct() {
        let a = makeItem(kind: .spec, name: "Design", path: "/p/docs/specs/a.md")
        let b = makeItem(kind: .spec, name: "Design", path: "/p/docs/specs/b.md")
        XCTAssertNotEqual(a.id, b.id)
    }

    func testNonContextIDsKeepTheScopeNameShape() {
        let item = makeItem(kind: .mcpServer, name: "srv", path: "/p/.mcp.json")
        XCTAssertEqual(item.id, "mcpServer|Project|srv")
    }

    // MARK: - Doc mapping

    private let projectRoot = URL(fileURLWithPath: "/project")

    private func makeDoc(
        kind: PlanDoc.Kind,
        fileName: String,
        title: String = "A Title",
        date: String? = nil
    ) -> PlanDoc {
        PlanDoc(
            fileURL: URL(fileURLWithPath: "/project/docs/plans/\(fileName)"),
            kind: kind, title: title, date: date, goal: nil,
            specReference: nil, checkedSteps: 0, totalSteps: 0, tasks: [])
    }

    func testDocMappingAnatomy() {
        let doc = makeDoc(kind: .plan, fileName: "2026-08-01-merge.md",
                          title: "Merge Plan", date: "2026-08-01")
        let items = LibraryContext.docItems(docs: [doc], projectRoot: projectRoot)
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item.kind, .plan)
        XCTAssertEqual(item.name, "Merge Plan")
        XCTAssertEqual(item.description, "2026-08-01-merge.md")
        XCTAssertEqual(item.scopeLabel, "Project")
        XCTAssertTrue(item.accessible)
        XCTAssertEqual(item.accessReason,
                       "In this project's shared docs — read by agents")
        XCTAssertEqual(item.detail,
                       ["docs/plans/2026-08-01-merge.md", "2026-08-01"])
    }

    func testEmptyTitleFallsBackToFilename() {
        let doc = makeDoc(kind: .spec, fileName: "2026-08-01-x-design.md", title: "")
        let items = LibraryContext.docItems(docs: [doc], projectRoot: projectRoot)
        XCTAssertEqual(items[0].name, "2026-08-01-x-design.md")
    }

    func testDocKindIsExcluded() {
        let doc = makeDoc(kind: .doc, fileName: "notes.md")
        XCTAssertTrue(
            LibraryContext.docItems(docs: [doc], projectRoot: projectRoot).isEmpty)
    }

    func testDateOmittedFromDetailWhenAbsent() {
        let doc = makeDoc(kind: .plan, fileName: "undated.md", date: nil)
        let items = LibraryContext.docItems(docs: [doc], projectRoot: projectRoot)
        XCTAssertEqual(items[0].detail, ["docs/plans/undated.md"])
    }

    func testPlansLeadSpecsAndEachSortNewestFirst() {
        let oldPlan = makeDoc(kind: .plan, fileName: "2026-01-01-a.md")
        let newPlan = makeDoc(kind: .plan, fileName: "2026-08-01-b.md")
        let oldSpec = makeDoc(kind: .spec, fileName: "2026-02-01-c.md")
        let newSpec = makeDoc(kind: .spec, fileName: "2026-07-01-d.md")
        let items = LibraryContext.docItems(
            docs: [oldPlan, oldSpec, newPlan, newSpec], projectRoot: projectRoot)
        XCTAssertEqual(items.map(\.description),
                       ["2026-08-01-b.md", "2026-01-01-a.md",
                        "2026-07-01-d.md", "2026-02-01-c.md"])
        XCTAssertEqual(items.map(\.kind), [.plan, .plan, .spec, .spec])
    }

    func testMappedSameTitleDocsGetDistinctIDs() {
        let a = makeDoc(kind: .spec, fileName: "2026-08-01-x-design.md", title: "Design")
        let b = makeDoc(kind: .spec, fileName: "2026-07-01-y-design.md", title: "Design")
        let ids = LibraryContext.docItems(docs: [a, b], projectRoot: projectRoot).map(\.id)
        XCTAssertEqual(Set(ids).count, 2)
    }

    // MARK: - Config files

    private func makeTempRoot(files: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        for name in files {
            try "x".write(to: dir.appendingPathComponent(name),
                          atomically: true, encoding: .utf8)
        }
        return dir
    }

    func testConfigListsOnlyExistingFilesInStableOrder() throws {
        let root = try makeTempRoot(files: ["README.md", "CLAUDE.md", "unrelated.txt"])
        defer { try? FileManager.default.removeItem(at: root) }
        let items = LibraryContext.configItems(projectRoot: root)
        XCTAssertEqual(items.map(\.name), ["CLAUDE.md", "README.md"])
    }

    func testConfigBlurbsAndAnatomy() throws {
        let root = try makeTempRoot(files: LibraryContext.configFileNames)
        defer { try? FileManager.default.removeItem(at: root) }
        let items = LibraryContext.configItems(projectRoot: root)
        XCTAssertEqual(items.map(\.name),
                       ["CLAUDE.md", "AGENTS.md", "GEMINI.md", "run.toml", "README.md"])
        XCTAssertEqual(items.map(\.description),
                       ["Claude Code project instructions", "Agent instructions",
                        "Gemini instructions", "Run configuration", "Project readme"])
        for item in items {
            XCTAssertEqual(item.kind, .configFile)
            XCTAssertEqual(item.scopeLabel, "Project")
            XCTAssertTrue(item.accessible)
            XCTAssertEqual(item.accessReason,
                           "At the project root — read by agents working here")
            XCTAssertEqual(item.detail, [item.name])
        }
    }
}
