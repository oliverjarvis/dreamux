import Foundation
@testable import Dreamux

/// Per-test scratch space. Every test that touches the filesystem must
/// route through one of these so nothing ever lands in ~/Documents or
/// real Application Support — the sandbox lives under the system temp
/// directory with a UUID suffix, so parallel test runs can't collide.
///
/// Typical use:
///
///     var sandbox: TestSandbox!
///     override func setUpWithError() throws { sandbox = try TestSandbox() }
///     override func tearDown() { sandbox.destroy(); sandbox = nil }
///
final class TestSandbox {
    /// Root of this test's private scratch directory. Everything the
    /// test creates should live below here.
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DreamuxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Delete the entire sandbox. Call from `tearDown` — best-effort,
    /// since a half-torn-down temp dir is harmless and shouldn't fail
    /// the test that's already finishing.
    func destroy() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Create `<sandbox>/<name>/` and wrap it in a `Project`, mirroring
    /// what `ProjectStore.createProject` produces — minus the persisted
    /// projects.json, which tests don't need.
    func makeProject(named name: String) throws -> Project {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Project(name: name, rootPath: url)
    }
}

/// Locations of the git-tracked fixtures under `Tests/Fixtures/`. The
/// test target can't bundle them as SwiftPM resources (they include an
/// executable shim and files that must keep exact bytes), so we anchor
/// on `#filePath` instead — fine here because tests always run from a
/// checkout.
enum RepoFixtures {
    /// `<checkout>/Tests/Fixtures`
    static var root: URL {
        URL(fileURLWithPath: #filePath)        // .../Tests/DreamuxTests/Support/TestSandbox.swift
            .deletingLastPathComponent()        // .../Tests/DreamuxTests/Support
            .deletingLastPathComponent()        // .../Tests/DreamuxTests
            .deletingLastPathComponent()        // .../Tests
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// The fake `claude` CLI shim used by e2e flows (detect / isolate /
    /// diagnose). Put its directory first on PATH to impersonate the
    /// real CLI.
    static var fakeClaude: URL {
        root.appendingPathComponent("bin/claude")
    }

    /// `Tests/Fixtures/sample-apps/<name>/`
    static func sampleApp(_ name: String) -> URL {
        root.appendingPathComponent("sample-apps", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Read a sample app's top-level files into the `[path: contents]`
    /// shape `GitFixtures` helpers take, so a test can commit a copy of
    /// the fixture into a sandboxed repo without sharing state with the
    /// checkout.
    static func sampleAppFiles(_ name: String) throws -> [String: String] {
        let dir = sampleApp(name)
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var files: [String: String] = [:]
        for url in entries {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            files[url.lastPathComponent] = try String(contentsOf: url, encoding: .utf8)
        }
        return files
    }
}
