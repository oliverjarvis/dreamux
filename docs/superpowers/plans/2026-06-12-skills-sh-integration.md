# Skills.sh Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Browse the skills.sh registry, preview a skill's files, install via `npx skills`, and manage installed skills — per Dreamux project and globally.

**Architecture:** Hybrid, per the approved spec (`docs/superpowers/specs/2026-06-12-skills-sh-integration-design.md`): browsing hits the public `https://skills.sh/api/search` JSON endpoint; file preview shallow-clones the skill's GitHub repo via existing `GitOperations`; all mutations and the installed list go through `npx skills`. Project-scope installs land canonically at `<project>/.agents/skills/` and a `SkillLinker` fans symlinks out into every repo worktree (agents only discover skills up to the repository root), suppressing git noise via a managed block in each repo's `.bare/info/exclude`.

**Tech Stack:** Swift 6 / SwiftUI (macOS 14), `@Observable` stores, `Process`-based async shell helpers, XCTest, python fixture CLIs, existing unix-socket e2e harness.

**Verified CLI/API facts (probed 2026-06-12, CLI via `npx -y skills`):**
- `skills add <owner/repo> -s <names…> -a <agents…> [-g] -y` — non-interactive with `-y`; prints "No matching skills found for: X" + available list when `-s` doesn't match; canonical copies land in `<cwd>/.agents/skills/<name>/`, lockfile `<cwd>/skills-lock.json`.
- `skills list --json [-g]` → JSON array: `[{"name": "...", "path": "/abs/.agents/skills/<name>", "scope": "project"|"global", "agents": ["Cursor", ...]}]`.
- `skills remove -s <names…> -a <agents…> [--global] -y`, `skills update [-g|-p] -y`.
- Search endpoint (public, no auth): `GET https://skills.sh/api/search?q=<query>&limit=<n>` → `{"query":"react","searchType":"fuzzy","skills":[{"id":"vercel-labs/agent-skills/vercel-react-best-practices","skillId":"vercel-react-best-practices","name":"vercel-react-best-practices","installs":471525,"source":"vercel-labs/agent-skills"}],"count":3,"duration_ms":464}`. Minimum 2-char query (else `{"error":"Query must be at least 2 characters"}`).
- The v1 API (`/api/v1/*`) requires Vercel OIDC auth — never use it.
- Node failure mode to handle: asdf shims present but no version set → running `node`/`npx` exits non-zero with "No version is set".

**Environment overrides introduced by this plan (all mirror existing `DREAMUX_CLAUDE_BIN`/`DREAMUX_GH_BIN` conventions):**
- `DREAMUX_SKILLS_BIN` — executable replacing `npx -y skills`; invoked with the subcommand argv directly.
- `DREAMUX_SKILLS_API_BASE` — base URL replacing `https://skills.sh`.
- `DREAMUX_SKILLS_CACHE_DIR` — preview clone cache root (default `~/Library/Caches/Dreamux/skill-previews`).
- `DREAMUX_SKILLS_GIT_BASE` — prefix for resolving `<owner>/<repo>` clone URLs (default `https://github.com/`; tests point it at a local fixtures dir).
- `SKILLS_FAKE_GLOBAL_DIR` — consumed by the fake CLI only: where "global" installs land.
- `SKILLS_FAKE_LOG` — consumed by the fake CLI only: JSONL argv log for assertions.

**File structure:**

| File | Responsibility |
|---|---|
| `Sources/Dreamux/Models/SkillTypes.swift` (create) | `SkillScope`, `RegistrySkill`, `InstalledSkill`, search-response decoding |
| `Sources/Dreamux/Shell/SkillsRegistryClient.swift` (create) | public search endpoint client |
| `Sources/Dreamux/Shell/NodeDetector.swift` (create) | find a node bin dir that actually executes |
| `Sources/Dreamux/Shell/SkillsCLI.swift` (create) | async wrapper around `npx -y skills` |
| `Sources/Dreamux/Shell/SkillLinker.swift` (create) | project-scope symlink fan-out + exclude management |
| `Sources/Dreamux/Shell/SkillPreviewCache.swift` (create) | shallow-clone cache + skill file listing |
| `Sources/Dreamux/Models/SkillsStore.swift` (create) | `@Observable` orchestration per scope |
| `Sources/Dreamux/Models/AppSection.swift` (modify) | add `.skills` |
| `Sources/Dreamux/Views/ProjectWindow.swift`, `Views/ContentView.swift` (modify) | lift signals trio up; wire Skills section |
| `Sources/Dreamux/Views/SkillsBrowserView.swift` (create) | sidebar (installed) + search/topics/results |
| `Sources/Dreamux/Views/SkillDetailView.swift` (create) | file tree + preview + install/remove/update |
| `Sources/Dreamux/DreamuxApp.swift`, `Views/HomeView.swift` (modify) | global Skills window + Home button |
| `Sources/Dreamux/Shell/FeatureProvisioner.swift` (modify) | reconcile links when worktrees appear |
| `Sources/Dreamux/E2E/E2ERegistry.swift`, `E2E/E2ECommands.swift` (modify) | section switching + skills commands |
| `Tests/Fixtures/bin/skills` (create) | fake CLI |
| `Scripts/e2e/skills-api-stub.py` (create), `Scripts/e2e/run-e2e.sh`, `driver.py`, `PROTOCOL.md` (modify) | e2e scenario |
| `Tests/DreamuxTests/Skill*.swift` (create) | unit/integration tests per component |

Conventions to follow throughout: tests are `@MainActor final class …Tests: XCTestCase` using `TestSandbox` + `GitFixtures` (see `Tests/DreamuxTests/FeatureProvisionerTests.swift`); git identity env vars in `setUp` exactly as that file does; process helpers mirror `GitOperations.runGit`/`GhOperations`.

---

### Task 1: Skill value types + JSON decoding

**Files:**
- Create: `Sources/Dreamux/Models/SkillTypes.swift`
- Test: `Tests/DreamuxTests/SkillTypesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Dreamux

final class SkillTypesTests: XCTestCase {
    /// Real response shape captured from skills.sh/api/search 2026-06-12.
    func testDecodesSearchResponse() throws {
        let json = #"""
        {"query":"react","searchType":"fuzzy","skills":[
          {"id":"vercel-labs/agent-skills/vercel-react-best-practices",
           "skillId":"vercel-react-best-practices",
           "name":"vercel-react-best-practices",
           "installs":471525,
           "source":"vercel-labs/agent-skills"}],
         "count":1,"duration_ms":464}
        """#
        let response = try JSONDecoder().decode(SkillSearchResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.skills.count, 1)
        let skill = try XCTUnwrap(response.skills.first)
        XCTAssertEqual(skill.id, "vercel-labs/agent-skills/vercel-react-best-practices")
        XCTAssertEqual(skill.skillId, "vercel-react-best-practices")
        XCTAssertEqual(skill.installs, 471525)
        XCTAssertEqual(skill.source, "vercel-labs/agent-skills")
    }

    /// Real `skills list --json` shape captured from CLI probe 2026-06-12.
    func testDecodesInstalledList() throws {
        let json = #"""
        [{"name":"web-design-guidelines",
          "path":"/tmp/proj/.agents/skills/web-design-guidelines",
          "scope":"project",
          "agents":["Cursor"]}]
        """#
        let skills = try JSONDecoder().decode([InstalledSkill].self, from: Data(json.utf8))
        XCTAssertEqual(skills.first?.name, "web-design-guidelines")
        XCTAssertEqual(skills.first?.scope, "project")
        XCTAssertEqual(skills.first?.id, "/tmp/proj/.agents/skills/web-design-guidelines")
    }

    func testScopeWorkingDirectory() {
        let projectURL = URL(fileURLWithPath: "/tmp/proj", isDirectory: true)
        XCTAssertEqual(SkillScope.project(projectURL).workingDirectory.path, "/tmp/proj")
        XCTAssertFalse(SkillScope.project(projectURL).isGlobal)
        XCTAssertTrue(SkillScope.global.isGlobal)
        XCTAssertEqual(SkillScope.global.workingDirectory.path, NSHomeDirectory())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SkillTypesTests 2>&1 | tail -5`
Expected: compile FAILURE — `cannot find 'SkillSearchResponse' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Scope a skill operation applies to: the user's home directory (`-g`
/// installs, picked up by agents everywhere) or one Dreamux project's
/// root, where canonical copies live under `<project>/.agents/skills/`.
enum SkillScope: Hashable, Sendable {
    case global
    case project(URL)

    /// Directory `npx skills` runs in. Global commands also pass `-g`,
    /// so for them the cwd only needs to exist.
    var workingDirectory: URL {
        switch self {
        case .global:
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        case .project(let root):
            return root
        }
    }

    var isGlobal: Bool {
        if case .global = self { return true }
        return false
    }
}

/// One result row from the public search endpoint
/// (`https://skills.sh/api/search?q=…`).
struct RegistrySkill: Identifiable, Hashable, Decodable, Sendable {
    /// Stable registry id: `<owner>/<repo>/<skill>`.
    let id: String
    /// Skill slug within its source repo — what `add -s` takes.
    let skillId: String
    let name: String
    let installs: Int
    /// `<owner>/<repo>` — what `npx skills add` takes as its package.
    let source: String

    /// Public page for the skill, used as a fallback when preview fails.
    var webURL: URL? {
        URL(string: "https://skills.sh/\(source)/\(skillId)")
    }
}

struct SkillSearchResponse: Decodable, Sendable {
    let skills: [RegistrySkill]
}

/// One entry from `npx skills list --json`.
struct InstalledSkill: Identifiable, Hashable, Decodable, Sendable {
    let name: String
    /// Canonical on-disk path (`…/.agents/skills/<name>`).
    let path: String
    /// "project" or "global", as the CLI reports it.
    let scope: String
    let agents: [String]

    var id: String { path }
    var isGlobal: Bool { scope == "global" }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SkillTypesTests 2>&1 | tail -5`
Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/SkillTypes.swift Tests/DreamuxTests/SkillTypesTests.swift
git commit -m "Add skill value types and registry/CLI JSON decoding"
```

---

### Task 2: SkillsRegistryClient (public search endpoint)

**Files:**
- Create: `Sources/Dreamux/Shell/SkillsRegistryClient.swift`
- Test: `Tests/DreamuxTests/SkillsRegistryClientTests.swift`

- [ ] **Step 1: Write the failing test** (uses a `URLProtocol` stub — no network)

```swift
import XCTest
@testable import Dreamux

/// Intercepts every request on a private URLSession so client tests
/// run with zero network. Set `handler` per test.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SkillsRegistryClientTests: XCTestCase {
    private var client: SkillsRegistryClient!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        client = SkillsRegistryClient(
            baseURL: URL(string: "https://stub.test")!,
            session: URLSession(configuration: config)
        )
    }

    override func tearDown() { StubURLProtocol.handler = nil }

    func testSearchBuildsQueryAndDecodes() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/search")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            XCTAssertEqual(components.queryItems?.first { $0.name == "q" }?.value, "react")
            XCTAssertEqual(components.queryItems?.first { $0.name == "limit" }?.value, "30")
            let body = #"{"skills":[{"id":"a/b/c","skillId":"c","name":"c","installs":5,"source":"a/b"}]}"#
            return (200, Data(body.utf8))
        }
        let results = try await client.search(query: "react")
        XCTAssertEqual(results.map(\.id), ["a/b/c"])
    }

    func testShortQueryThrowsWithoutRequest() async {
        StubURLProtocol.handler = { _ in
            XCTFail("no request should be made for a 1-char query")
            return (500, Data())
        }
        do {
            _ = try await client.search(query: "r")
            XCTFail("expected queryTooShort")
        } catch SkillsRegistryError.queryTooShort {
        } catch { XCTFail("unexpected error: \(error)") }
    }

    func testNon200Throws() async {
        StubURLProtocol.handler = { _ in (503, Data()) }
        do {
            _ = try await client.search(query: "react")
            XCTFail("expected badStatus")
        } catch SkillsRegistryError.badStatus(let code) {
            XCTAssertEqual(code, 503)
        } catch { XCTFail("unexpected error: \(error)") }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SkillsRegistryClientTests 2>&1 | tail -5`
Expected: compile FAILURE — `cannot find 'SkillsRegistryClient' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

enum SkillsRegistryError: LocalizedError {
    case queryTooShort
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .queryTooShort:
            return "Search needs at least 2 characters."
        case .badStatus(let code):
            return "skills.sh search failed (HTTP \(code))."
        }
    }
}

/// Minimal client for the public skills.sh search endpoint — the same
/// one `skills find` uses. The full v1 registry API requires Vercel
/// OIDC auth, so search is the only endpoint we consume.
/// `DREAMUX_SKILLS_API_BASE` points this at a local stub during
/// tests/e2e, mirroring the `DREAMUX_*_BIN` overrides.
struct SkillsRegistryClient: Sendable {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL? = nil, session: URLSession = .shared) {
        if let baseURL {
            self.baseURL = baseURL
        } else if let override = ProcessInfo.processInfo.environment["DREAMUX_SKILLS_API_BASE"],
                  !override.isEmpty, let url = URL(string: override) {
            self.baseURL = url
        } else {
            self.baseURL = URL(string: "https://skills.sh")!
        }
        self.session = session
    }

    /// Search the registry. The endpoint rejects queries under 2 chars,
    /// so we pre-empt with a typed error the UI can treat as "idle".
    func search(query: String, limit: Int = 30) async throws -> [RegistrySkill] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { throw SkillsRegistryError.queryTooShort }

        var components = URLComponents(
            url: baseURL.appending(path: "api/search"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let (data, response) = try await session.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw SkillsRegistryError.badStatus(status) }
        return try JSONDecoder().decode(SkillSearchResponse.self, from: data).skills
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SkillsRegistryClientTests 2>&1 | tail -5`
Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Shell/SkillsRegistryClient.swift Tests/DreamuxTests/SkillsRegistryClientTests.swift
git commit -m "Add skills.sh public search client"
```

---

### Task 3: NodeDetector

**Files:**
- Create: `Sources/Dreamux/Shell/NodeDetector.swift`
- Test: `Tests/DreamuxTests/NodeDetectorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Dreamux

final class NodeDetectorTests: XCTestCase {
    private var sandboxDir: URL!

    override func setUp() throws {
        sandboxDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("node-detector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: sandboxDir) }

    /// Write an executable fake `node` into a fresh dir; `script` is the
    /// shell body (e.g. `echo v24.0.0` or `exit 1` for a broken shim).
    private func makeNodeDir(_ name: String, script: String) throws -> String {
        let dir = sandboxDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let node = dir.appendingPathComponent("node")
        try "#!/bin/sh\n\(script)\n".write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        return dir.path
    }

    func testSkipsBrokenShimAndPicksWorkingNode() async throws {
        // The asdf failure mode: shim exists and is executable but dies.
        let broken = try makeNodeDir("shims", script: "echo 'No version is set' >&2; exit 1")
        let working = try makeNodeDir("real", script: "echo v24.13.0")

        let resolution = await NodeDetector.detect(candidates: [broken, working])
        XCTAssertEqual(resolution?.binDirectory, working)
        XCTAssertEqual(resolution?.version, "v24.13.0")
    }

    func testNoWorkingNodeReturnsNil() async throws {
        let broken = try makeNodeDir("shims", script: "exit 1")
        let resolution = await NodeDetector.detect(candidates: [broken, "/nonexistent/dir"])
        XCTAssertNil(resolution)
    }

    func testDefaultCandidatesIncludeWellKnownLocations() async {
        let candidates = await NodeDetector.defaultCandidates()
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin"))
        XCTAssertTrue(candidates.contains("/usr/local/bin"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NodeDetectorTests 2>&1 | tail -5`
Expected: compile FAILURE — `cannot find 'NodeDetector' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Finds a node installation that actually runs. `npx` (which
/// `SkillsCLI` uses) needs node, but Dreamux.app launches with a
/// minimal GUI environment — and even a login shell can resolve `node`
/// to a broken asdf shim ("No version is set"). So candidates are
/// gathered (login-shell PATH first, then version managers
/// newest-first, then Homebrew/system) and each is *executed*
/// (`node --version`) until one works.
enum NodeDetector {
    struct Resolution: Equatable, Sendable {
        /// Directory containing working `node` and `npx` binaries.
        let binDirectory: String
        let version: String
    }

    static func detect() async -> Resolution? {
        await detect(candidates: await defaultCandidates())
    }

    /// Test seam: probe an explicit candidate list, in order.
    static func detect(candidates: [String]) async -> Resolution? {
        let fm = FileManager.default
        for dir in candidates {
            let node = (dir as NSString).appendingPathComponent("node")
            guard fm.isExecutableFile(atPath: node) else { continue }
            if let version = await probeVersion(nodePath: node) {
                return Resolution(binDirectory: dir, version: version)
            }
        }
        return nil
    }

    static func defaultCandidates() async -> [String] {
        var dirs: [String] = []
        if let shellDir = await loginShellNodeDirectory() {
            dirs.append(shellDir)
        }
        let home = NSHomeDirectory()
        dirs += versionedBinDirs(under: "\(home)/.asdf/installs/nodejs")
        dirs += versionedBinDirs(under: "\(home)/.nvm/versions/node")
        dirs += ["/opt/homebrew/bin", "/usr/local/bin"]
        return dirs
    }

    // MARK: - Internals

    /// `~/.asdf/installs/nodejs/<v>/bin` etc., newest version first.
    private static func versionedBinDirs(under root: String) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return entries
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(root)/\($0)/bin" }
    }

    /// Where the user's login shell resolves `node` — respects their
    /// real setup (nvm/asdf init in zshrc/zprofile) when it works.
    private static func loginShellNodeDirectory() async -> String? {
        let output = await runProcess(
            executable: "/bin/zsh", arguments: ["-l", "-c", "command -v node"]
        )
        guard let path = output?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty, path.hasPrefix("/")
        else { return nil }
        return (path as NSString).deletingLastPathComponent
    }

    /// nil unless `node --version` exits 0 and prints a `v…` string.
    private static func probeVersion(nodePath: String) async -> String? {
        guard let output = await runProcess(executable: nodePath, arguments: ["--version"]) else {
            return nil
        }
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.hasPrefix("v") ? version : nil
    }

    /// Tiny process runner: stdout on success, nil on failed launch or
    /// non-zero exit. Probes are short-lived; no streaming needed.
    private static func runProcess(executable: String, arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter NodeDetectorTests 2>&1 | tail -5`
Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Shell/NodeDetector.swift Tests/DreamuxTests/NodeDetectorTests.swift
git commit -m "Add NodeDetector that probes for a working node binary"
```

---

### Task 4: Fake `skills` CLI fixture + SkillsCLI

**Files:**
- Create: `Tests/Fixtures/bin/skills` (python, `chmod +x`)
- Create: `Sources/Dreamux/Shell/SkillsCLI.swift`
- Test: `Tests/DreamuxTests/SkillsCLITests.swift`

- [ ] **Step 1: Write the fake CLI fixture**

```python
#!/usr/bin/env python3
"""fake skills — Dreamux's test stand-in for `npx -y skills`.

Pointed at via DREAMUX_SKILLS_BIN so SkillsCLI/SkillsStore tests and
the e2e harness exercise install/list/remove/update with no network
and no node. Maintains real `.agents/skills/<name>/SKILL.md` dirs under
a "scope root": the cwd for project scope, $SKILLS_FAKE_GLOBAL_DIR for
-g/--global (required when a global flag is passed, so tests never
touch the real home directory).

Every invocation is appended as a JSON line to $SKILLS_FAKE_LOG (when
set) for argv assertions.

Supported invocations (the only ones SkillsCLI makes):
    skills add <source> -s <names...> -a <agents...> [-g] -y
    skills list --json [-g]
    skills remove -s <names...> -a <agents...> [--global] -y
    skills update [<names...>] (-g|-p) -y
"""
import json
import os
import sys


def fail(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def log_invocation(argv):
    path = os.environ.get("SKILLS_FAKE_LOG")
    if path:
        with open(path, "a") as f:
            f.write(json.dumps({"argv": argv, "cwd": os.getcwd()}) + "\n")


def parse(argv):
    """Split argv into positionals and flag→values lists. -s/-a absorb
    values until the next flag; bare flags map to []."""
    flags, positionals, current = {}, [], None
    for arg in argv:
        if arg.startswith("-"):
            current = arg
            flags.setdefault(current, [])
        elif current is not None:
            flags[current].append(arg)
        else:
            positionals.append(arg)
    return positionals, flags


def is_global(flags):
    return "-g" in flags or "--global" in flags


def scope_root(flags):
    if is_global(flags):
        root = os.environ.get("SKILLS_FAKE_GLOBAL_DIR")
        if not root:
            fail("fake-skills: global op without SKILLS_FAKE_GLOBAL_DIR")
        os.makedirs(root, exist_ok=True)
        return root
    return os.getcwd()


def skills_dir(flags):
    return os.path.join(scope_root(flags), ".agents", "skills")


def cmd_add(positionals, flags):
    if not positionals:
        fail("fake-skills: add needs a source")
    names = flags.get("-s") or flags.get("--skill") or []
    if not names:
        fail("fake-skills: add needs -s")
    base = skills_dir(flags)
    for name in names:
        d = os.path.join(base, name)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "SKILL.md"), "w") as f:
            f.write("---\nname: %s\ndescription: fake\n---\nfake skill body\n" % name)
    # Lockfile presence mirrors the real CLI closely enough for tests.
    with open(os.path.join(scope_root(flags), "skills-lock.json"), "w") as f:
        json.dump({"skills": sorted(os.listdir(base))}, f)
    print("Installed %d skill(s)" % len(names))


def cmd_list(flags):
    base = skills_dir(flags)
    scope = "global" if is_global(flags) else "project"
    entries = sorted(os.listdir(base)) if os.path.isdir(base) else []
    print(json.dumps([
        {"name": n, "path": os.path.join(base, n), "scope": scope,
         "agents": ["claude-code", "codex"]}
        for n in entries
        if os.path.isdir(os.path.join(base, n))
    ]))


def cmd_remove(positionals, flags):
    names = (flags.get("-s") or flags.get("--skill") or []) + positionals
    base = skills_dir(flags)
    for name in names:
        d = os.path.join(base, name)
        if os.path.isdir(d):
            import shutil
            shutil.rmtree(d)
    print("Removed %d skill(s)" % len(names))


def main():
    argv = sys.argv[1:]
    log_invocation(argv)
    if not argv:
        fail("fake-skills: no arguments")
    positionals, flags = parse(argv[1:])
    if argv[0] == "add":
        cmd_add(positionals, flags)
    elif argv[0] in ("list", "ls"):
        cmd_list(flags)
    elif argv[0] in ("remove", "rm"):
        cmd_remove(positionals, flags)
    elif argv[0] in ("update", "upgrade"):
        print("Updated")
    else:
        fail("fake-skills: unsupported subcommand " + argv[0])


if __name__ == "__main__":
    main()
```

Then: `chmod +x Tests/Fixtures/bin/skills`

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
@testable import Dreamux

/// Integration tests for SkillsCLI against the fake `skills` fixture —
/// asserts exact argv/cwd construction and JSON parsing, no node/npm.
@MainActor
final class SkillsCLITests: XCTestCase {
    private var sandbox: TestSandbox!
    private var projectRoot: URL!
    private var globalDir: URL!
    private var logURL: URL!

    /// Repo-relative fixture path, resolved the same way other tests
    /// reach Tests/Fixtures (#filePath-relative).
    static var fakeSkillsBin: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // DreamuxTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Fixtures/bin/skills").path
    }

    override func setUp() async throws {
        sandbox = try TestSandbox()
        projectRoot = try sandbox.makeProject(named: "proj").rootPath
        globalDir = projectRoot.deletingLastPathComponent()
            .appendingPathComponent("fake-global", isDirectory: true)
        logURL = projectRoot.deletingLastPathComponent()
            .appendingPathComponent("invocations.jsonl")
        setenv("DREAMUX_SKILLS_BIN", Self.fakeSkillsBin, 1)
        setenv("SKILLS_FAKE_GLOBAL_DIR", globalDir.path, 1)
        setenv("SKILLS_FAKE_LOG", logURL.path, 1)
    }

    override func tearDown() async throws {
        unsetenv("DREAMUX_SKILLS_BIN")
        unsetenv("SKILLS_FAKE_GLOBAL_DIR")
        unsetenv("SKILLS_FAKE_LOG")
        sandbox?.destroy()
        sandbox = nil
    }

    private var cli: SkillsCLI { SkillsCLI(nodeBinDirectory: nil) }

    private func loggedInvocations() throws -> [[String: Any]] {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    func testAddInstallsAndLocksAgents() async throws {
        try await cli.add(
            source: "vercel-labs/agent-skills",
            skills: ["web-design-guidelines"],
            extraAgents: ["cursor"],
            scope: .project(projectRoot)
        )
        // Canonical copy in the project root.
        let canonical = projectRoot.appendingPathComponent(
            ".agents/skills/web-design-guidelines/SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonical.path))

        // Exact argv: locked agents always present, extras appended,
        // -y always, cwd = project root.
        let invocation = try XCTUnwrap(loggedInvocations().last)
        let argv = try XCTUnwrap(invocation["argv"] as? [String])
        XCTAssertEqual(argv, [
            "add", "vercel-labs/agent-skills",
            "-s", "web-design-guidelines",
            "-a", "claude-code", "codex", "cursor",
            "-y",
        ])
        XCTAssertEqual(invocation["cwd"] as? String, "/private" + projectRoot.path)
    }

    func testAddGlobalPassesG() async throws {
        try await cli.add(
            source: "anthropics/skills", skills: ["s1"], extraAgents: [], scope: .global
        )
        let argv = try XCTUnwrap(loggedInvocations().last?["argv"] as? [String])
        XCTAssertTrue(argv.contains("-g"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: globalDir.appendingPathComponent(".agents/skills/s1/SKILL.md").path))
    }

    func testListParsesBothScopes() async throws {
        try await cli.add(source: "a/b", skills: ["p1"], extraAgents: [], scope: .project(projectRoot))
        try await cli.add(source: "a/b", skills: ["g1"], extraAgents: [], scope: .global)

        let project = try await cli.list(scope: .project(projectRoot))
        XCTAssertEqual(project.map(\.name), ["p1"])
        XCTAssertEqual(project.first?.scope, "project")

        let global = try await cli.list(scope: .global)
        XCTAssertEqual(global.map(\.name), ["g1"])
        XCTAssertEqual(global.first?.isGlobal, true)
    }

    func testRemoveDeletesInstall() async throws {
        try await cli.add(source: "a/b", skills: ["p1"], extraAgents: [], scope: .project(projectRoot))
        try await cli.remove(skills: ["p1"], scope: .project(projectRoot))
        let remaining = try await cli.list(scope: .project(projectRoot))
        XCTAssertTrue(remaining.isEmpty)
        let argv = try XCTUnwrap(loggedInvocations().last?["argv"] as? [String])
        XCTAssertEqual(argv, ["remove", "-s", "p1", "-a", "*", "-y"])
    }

    func testNodeUnavailableWithoutOverride() async {
        unsetenv("DREAMUX_SKILLS_BIN")
        do {
            _ = try await SkillsCLI(nodeBinDirectory: nil).list(scope: .global)
            XCTFail("expected nodeUnavailable")
        } catch SkillsCLIError.nodeUnavailable {
        } catch { XCTFail("unexpected error: \(error)") }
    }
}
```

Note the `"/private" + projectRoot.path` assertion: `TestSandbox` lives in `/tmp`, which is a symlink to `/private/tmp` — python's `os.getcwd()` reports the resolved path. If `TestSandbox` already standardizes paths, drop the prefix; run the test and match reality.

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter SkillsCLITests 2>&1 | tail -5`
Expected: compile FAILURE — `cannot find 'SkillsCLI' in scope`

- [ ] **Step 4: Write the implementation**

```swift
import Foundation

enum SkillsCLIError: LocalizedError {
    case nodeUnavailable
    case commandFailed(args: [String], stderr: String)

    var errorDescription: String? {
        switch self {
        case .nodeUnavailable:
            return "Node.js is required to manage skills. Install it (e.g. `brew install node`) and reopen this section."
        case .commandFailed(let args, let stderr):
            let cmd = (["skills"] + args).joined(separator: " ")
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "skills command failed: \(cmd)" : "skills: \(trimmed)"
        }
    }
}

/// Async wrapper around the `skills` CLI (`npx -y skills …`) — the
/// canonical package manager for agent skills. All mutations and the
/// installed listing go through it so on-disk layout, lockfiles, and
/// update semantics stay exactly what the CLI produces.
///
/// Binary resolution: `DREAMUX_SKILLS_BIN` (tests/e2e) is executed
/// directly with the subcommand argv; otherwise we exec
/// `<nodeBinDirectory>/npx -y skills <argv…>` with that directory
/// prepended to PATH (npx needs to find its own node).
struct SkillsCLI: Sendable {
    /// Locked-on targets per product decision: every install reaches
    /// at least Claude Code and Codex.
    static let lockedAgents = ["claude-code", "codex"]

    let nodeBinDirectory: String?

    func add(
        source: String,
        skills: [String],
        extraAgents: [String],
        scope: SkillScope,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws {
        var args = ["add", source]
        args += ["-s"] + skills
        args += ["-a"] + Self.lockedAgents + extraAgents
        if scope.isGlobal { args.append("-g") }
        args.append("-y")
        _ = try await run(args, cwd: scope.workingDirectory, onLine: onLine)
    }

    func list(scope: SkillScope) async throws -> [InstalledSkill] {
        var args = ["list", "--json"]
        if scope.isGlobal { args.append("-g") }
        let output = try await run(args, cwd: scope.workingDirectory)
        // The CLI may print spinner noise before the payload on some
        // terminals; the JSON array is the first `[`-rooted suffix.
        guard let start = output.firstIndex(of: "[") else { return [] }
        let payload = Data(String(output[start...]).utf8)
        return try JSONDecoder().decode([InstalledSkill].self, from: payload)
    }

    func remove(
        skills: [String],
        scope: SkillScope,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws {
        var args = ["remove", "-s"] + skills + ["-a", "*"]
        if scope.isGlobal { args.append("--global") }
        args.append("-y")
        _ = try await run(args, cwd: scope.workingDirectory, onLine: onLine)
    }

    func update(
        skills: [String],
        scope: SkillScope,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws {
        var args = ["update"] + skills
        args.append(scope.isGlobal ? "-g" : "-p")
        args.append("-y")
        _ = try await run(args, cwd: scope.workingDirectory, onLine: onLine)
    }

    // MARK: - Process plumbing

    /// (executable, leading args) for the current configuration.
    private func invocation() throws -> (String, [String]) {
        if let override = ProcessInfo.processInfo.environment["DREAMUX_SKILLS_BIN"],
           !override.isEmpty {
            return (override, [])
        }
        guard let nodeBinDirectory else { throw SkillsCLIError.nodeUnavailable }
        return ((nodeBinDirectory as NSString).appendingPathComponent("npx"), ["-y", "skills"])
    }

    /// Mirrors `GitOperations.runGit`'s contract: background queue,
    /// streamed lines, SIGTERM on task cancellation, stderr folded into
    /// the thrown error. (Same drain-unconditionally rationale — see
    /// the comment in GitOperations.swift.)
    private func run(
        _ args: [String],
        cwd: URL,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let (executable, leadingArgs) = try invocation()
        let nodeDir = nodeBinDirectory
        let processBox = SkillsProcessBox()

        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: executable)
                        process.arguments = leadingArgs + args
                        process.currentDirectoryURL = cwd

                        var env = ProcessInfo.processInfo.environment
                        if let nodeDir {
                            env["PATH"] = nodeDir + ":" + (env["PATH"] ?? "/usr/bin:/bin")
                        }
                        env["NO_COLOR"] = "1"
                        process.environment = env

                        let outPipe = Pipe()
                        let errPipe = Pipe()
                        process.standardOutput = outPipe
                        process.standardError = errPipe

                        let collector = SkillsOutputCollector()
                        outPipe.fileHandleForReading.readabilityHandler = { handle in
                            let data = handle.availableData
                            if data.isEmpty { handle.readabilityHandler = nil; return }
                            collector.append(data, isStdout: true, onLine: onLine)
                        }
                        errPipe.fileHandleForReading.readabilityHandler = { handle in
                            let data = handle.availableData
                            if data.isEmpty { handle.readabilityHandler = nil; return }
                            collector.append(data, isStdout: false, onLine: onLine)
                        }

                        processBox.set(process)
                        do {
                            try process.run()
                        } catch {
                            continuation.resume(throwing: error)
                            return
                        }
                        process.waitUntilExit()

                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        let tailOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                        let tailErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                        if !tailOut.isEmpty { collector.append(tailOut, isStdout: true, onLine: onLine) }
                        if !tailErr.isEmpty { collector.append(tailErr, isStdout: false, onLine: onLine) }

                        if process.terminationStatus != 0 {
                            let stderr = collector.stderrText
                            continuation.resume(throwing: SkillsCLIError.commandFailed(
                                args: args,
                                stderr: stderr.isEmpty ? collector.stdoutText : stderr
                            ))
                        } else {
                            continuation.resume(returning: collector.stdoutText)
                        }
                    }
                }
            },
            onCancel: { processBox.terminate() }
        )
    }
}

/// Same shape as GitOperations' private ProcessBox — that one isn't
/// visible outside its file.
private final class SkillsProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        process = p
    }

    func terminate() {
        lock.lock()
        let p = process
        lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()
    }
}

/// Accumulates both streams and emits complete lines to `onLine`.
private final class SkillsOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = ""
    private var stderr = ""
    private var lineBuffer = ""

    var stdoutText: String { lock.lock(); defer { lock.unlock() }; return stdout }
    var stderrText: String { lock.lock(); defer { lock.unlock() }; return stderr }

    func append(_ data: Data, isStdout: Bool, onLine: (@Sendable (String) -> Void)?) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        if isStdout { stdout += text } else { stderr += text }
        lineBuffer += text
        var lines: [String] = []
        while let idx = lineBuffer.firstIndex(of: "\n") {
            let raw = String(lineBuffer[..<idx])
            lineBuffer.removeSubrange(lineBuffer.startIndex...idx)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        lock.unlock()
        if let onLine {
            for line in lines { onLine(line) }
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter SkillsCLITests 2>&1 | tail -5`
Expected: `Executed 5 tests, with 0 failures` (fix the `/private` path prefix assertion if TestSandbox standardizes; match observed reality, don't fudge the production code)

- [ ] **Step 6: Commit**

```bash
git add Tests/Fixtures/bin/skills Sources/Dreamux/Shell/SkillsCLI.swift Tests/DreamuxTests/SkillsCLITests.swift
git commit -m "Add SkillsCLI wrapper and fake skills fixture"
```

---

### Task 5: SkillLinker (project-scope fan-out)

**Files:**
- Create: `Sources/Dreamux/Shell/SkillLinker.swift`
- Test: `Tests/DreamuxTests/SkillLinkerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Dreamux

/// SkillLinker tests against real git repos (TestSandbox + GitFixtures):
/// links in every worktree, exclude entries keep `git status` clean,
/// reconcile is idempotent, never touches repo-owned files, and cleans
/// up after uninstalls.
@MainActor
final class SkillLinkerTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!
    private var alpha: Repository!

    override func setUp() async throws {
        setenv("GIT_AUTHOR_NAME", "Dreamux Tests", 1)
        setenv("GIT_AUTHOR_EMAIL", "tests@dreamux.local", 1)
        setenv("GIT_COMMITTER_NAME", "Dreamux Tests", 1)
        setenv("GIT_COMMITTER_EMAIL", "tests@dreamux.local", 1)
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "proj")
        alpha = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "alpha", files: ["alpha.txt": "a\n"]
        )
    }

    override func tearDown() async throws {
        sandbox?.destroy()
        sandbox = nil
    }

    /// Drop a canonical project skill the way `npx skills add` would.
    private func installCanonicalSkill(_ name: String) throws {
        let dir = project.rootPath.appendingPathComponent(
            ".agents/skills/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(name)\n---\nbody\n".write(
            to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    private func mainWorktree() -> URL {
        alpha.rootURL.appendingPathComponent("main", isDirectory: true)
    }

    func testReconcileLinksSkillIntoWorktreeAndKeepsGitClean() async throws {
        try installCanonicalSkill("foo")
        let report = SkillLinker.reconcile(projectRoot: project.rootPath)
        XCTAssertTrue(report.skipped.isEmpty)

        let fm = FileManager.default
        for agentDir in [".agents", ".claude"] {
            let link = mainWorktree().appendingPathComponent("\(agentDir)/skills/foo")
            let dest = try fm.destinationOfSymbolicLink(atPath: link.path)
            // Relative target that resolves to the canonical copy.
            XCTAssertFalse(dest.hasPrefix("/"), "link must be relative, got \(dest)")
            let resolved = URL(fileURLWithPath: dest,
                               relativeTo: link.deletingLastPathComponent()).standardizedFileURL
            XCTAssertEqual(resolved.path,
                           project.rootPath.appendingPathComponent(".agents/skills/foo").standardizedFileURL.path)
            // Reading through the link proves it resolves.
            XCTAssertTrue(fm.fileExists(atPath: link.appendingPathComponent("SKILL.md").path))
        }

        // The load-bearing assertion: zero git noise.
        let status = try await GitOperations.runGit(["status", "--porcelain"], in: mainWorktree())
        XCTAssertEqual(status.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testReconcileCoversFeatureWorktrees() async throws {
        try installCanonicalSkill("foo")
        _ = try await FeatureProvisioner.provision(
            featureName: "feature-x", in: project, across: [alpha])
        SkillLinker.reconcile(projectRoot: project.rootPath)

        let featureWorktree = alpha.rootURL.appendingPathComponent("feature-x", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: featureWorktree.appendingPathComponent(".agents/skills/foo/SKILL.md").path))
        let status = try await GitOperations.runGit(["status", "--porcelain"], in: featureWorktree)
        XCTAssertEqual(status.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testReconcileIsIdempotent() async throws {
        try installCanonicalSkill("foo")
        SkillLinker.reconcile(projectRoot: project.rootPath)
        let excludeURL = alpha.rootURL.appendingPathComponent(".bare/info/exclude")
        let before = try String(contentsOf: excludeURL, encoding: .utf8)

        let second = SkillLinker.reconcile(projectRoot: project.rootPath)
        XCTAssertTrue(second.skipped.isEmpty)
        XCTAssertEqual(try String(contentsOf: excludeURL, encoding: .utf8), before)
    }

    func testRepoOwnedSkillIsNeverTouched() async throws {
        // A committed skill with the same name already in the worktree.
        let owned = mainWorktree().appendingPathComponent(".claude/skills/foo", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        try "repo-owned\n".write(
            to: owned.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        _ = try await GitOperations.runGit(["add", "-A"], in: mainWorktree())
        _ = try await GitOperations.runGit(
            ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "own skill"],
            in: mainWorktree())

        try installCanonicalSkill("foo")
        let report = SkillLinker.reconcile(projectRoot: project.rootPath)

        XCTAssertEqual(report.skipped.count, 1)
        var isSymlink = false
        if let values = try? owned.resourceValues(forKeys: [.isSymbolicLinkKey]) {
            isSymlink = values.isSymbolicLink ?? false
        }
        XCTAssertFalse(isSymlink, "repo-owned dir must not be replaced")
        XCTAssertEqual(
            try String(contentsOf: owned.appendingPathComponent("SKILL.md"), encoding: .utf8),
            "repo-owned\n")
    }

    func testUninstalledSkillLinksAreRemoved() async throws {
        try installCanonicalSkill("foo")
        SkillLinker.reconcile(projectRoot: project.rootPath)
        // Uninstall: canonical dir disappears (what `skills remove` does).
        try FileManager.default.removeItem(
            at: project.rootPath.appendingPathComponent(".agents/skills/foo"))
        SkillLinker.reconcile(projectRoot: project.rootPath)

        for agentDir in [".agents", ".claude"] {
            let link = mainWorktree().appendingPathComponent("\(agentDir)/skills/foo")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: link.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil,
                "stale link \(link.path) must be removed")
        }
        // Exclude block is emptied too.
        let exclude = (try? String(
            contentsOf: alpha.rootURL.appendingPathComponent(".bare/info/exclude"),
            encoding: .utf8)) ?? ""
        XCTAssertFalse(exclude.contains("foo"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SkillLinkerTests 2>&1 | tail -5`
Expected: compile FAILURE — `cannot find 'SkillLinker' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Report of one reconcile pass — surfaced in the UI and asserted in
/// tests. `skipped` lists collisions left untouched (a real file or
/// directory already sits where a link would go).
struct SkillLinkReport: Equatable, Sendable {
    var linked: [String] = []
    var skipped: [String] = []
}

/// Fans project-scope skills out to every git worktree in the project.
///
/// `npx skills add` (cwd = project root) puts canonical copies in
/// `<project>/.agents/skills/`. Agents, however, discover skills from
/// their starting directory up to the *repository* root — and every
/// agent in Dreamux starts inside a repo worktree, below the project
/// root, so the canonical copies are invisible to them. For each
/// worktree of each repo we therefore create
///
///     <worktree>/.agents/skills/<name> → relative link to canonical
///     <worktree>/.claude/skills/<name> → same target
///
/// (`.agents/skills` is the agentskills.io universal directory — Codex
/// and current Claude Code read it; the `.claude/skills` link covers
/// older Claude Code builds.) Feature aggregation dirs under
/// `features/<feature>/<repo>` are symlinks into these same worktrees,
/// so they're covered automatically.
///
/// Git noise is suppressed with a managed block in each repo's shared
/// `.bare/info/exclude` — local-only, never touches tracked files.
/// The pass is idempotent: stale links are repaired, links for
/// uninstalled skills removed, and anything that isn't a symlink into
/// the project's canonical store is left alone and reported.
enum SkillLinker {
    static let excludeBlockStart = "# >>> dreamux skills (managed) >>>"
    static let excludeBlockEnd = "# <<< dreamux skills (managed) <<<"
    private static let agentDirNames = [".agents", ".claude"]

    /// Skills canonically installed at the project root — the
    /// subdirectories of `<project>/.agents/skills/`.
    static func installedSkillNames(projectRoot: URL) -> [String] {
        let skillsDir = projectRoot.appendingPathComponent(".agents/skills", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: skillsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
            .map(\.lastPathComponent)
            .sorted()
    }

    @discardableResult
    static func reconcile(projectRoot: URL) -> SkillLinkReport {
        let skills = installedSkillNames(projectRoot: projectRoot)
        var report = SkillLinkReport()
        for repoDir in repoDirectories(projectRoot: projectRoot) {
            updateExcludeFile(repoRoot: repoDir, skills: skills)
            for worktree in Repository(rootURL: repoDir).worktrees {
                reconcile(worktree: worktree, projectRoot: projectRoot,
                          skills: skills, report: &report)
            }
        }
        return report
    }

    // MARK: - Worktree pass

    private static func reconcile(
        worktree: URL,
        projectRoot: URL,
        skills: [String],
        report: inout SkillLinkReport
    ) {
        let fm = FileManager.default
        let canonicalRoot = projectRoot
            .appendingPathComponent(".agents/skills", isDirectory: true)
            .standardizedFileURL

        for agentDir in agentDirNames {
            let skillsParent = worktree.appendingPathComponent(
                "\(agentDir)/skills", isDirectory: true)

            // Remove links of ours whose skill is no longer installed.
            let existing = (try? fm.contentsOfDirectory(atPath: skillsParent.path)) ?? []
            for entry in existing where !skills.contains(entry) {
                let url = skillsParent.appendingPathComponent(entry)
                if isOurLink(url, canonicalRoot: canonicalRoot) {
                    try? fm.removeItem(at: url)
                }
            }

            for skill in skills {
                let linkURL = skillsParent.appendingPathComponent(skill)
                let canonical = canonicalRoot.appendingPathComponent(skill, isDirectory: true)
                let target = relativePath(
                    from: skillsParent.standardizedFileURL, to: canonical.standardizedFileURL)

                if let existingDest = try? fm.destinationOfSymbolicLink(atPath: linkURL.path) {
                    if existingDest == target { continue }
                    if isOurLink(linkURL, canonicalRoot: canonicalRoot) {
                        try? fm.removeItem(at: linkURL)   // stale — repair below
                    } else {
                        report.skipped.append("\(linkURL.path) (foreign symlink)")
                        continue
                    }
                } else if fm.fileExists(atPath: linkURL.path) {
                    // Real file/dir — repo-owned skill. Never touch it.
                    report.skipped.append("\(linkURL.path) (repo-owned)")
                    continue
                }

                do {
                    try fm.createDirectory(at: skillsParent, withIntermediateDirectories: true)
                    try fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: target)
                    report.linked.append(linkURL.path)
                } catch {
                    report.skipped.append("\(linkURL.path) (\(error.localizedDescription))")
                }
            }

            removeIfEmpty(skillsParent)
            removeIfEmpty(worktree.appendingPathComponent(agentDir, isDirectory: true))
        }
    }

    /// A symlink we manage: its destination resolves inside the
    /// project's canonical skills store.
    private static func isOurLink(_ url: URL, canonicalRoot: URL) -> Bool {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        else { return false }
        let resolved = URL(fileURLWithPath: dest, relativeTo: url.deletingLastPathComponent())
            .standardizedFileURL
        return resolved.path.hasPrefix(canonicalRoot.path + "/")
            || resolved.path == canonicalRoot.path
    }

    private static func removeIfEmpty(_ dir: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? ["x"]
        if contents.isEmpty {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Exclude management

    /// Rewrite the managed block in `<repo>/.bare/info/exclude`. Git
    /// reads the common dir's info/exclude for every worktree, so one
    /// file per repo covers them all — and it's local-only, so tracked
    /// files never change.
    private static func updateExcludeFile(repoRoot: URL, skills: [String]) {
        let infoDir = repoRoot.appendingPathComponent(".bare/info", isDirectory: true)
        let excludeURL = infoDir.appendingPathComponent("exclude")
        let fm = FileManager.default
        guard fm.fileExists(atPath: repoRoot.appendingPathComponent(".bare").path) else { return }
        try? fm.createDirectory(at: infoDir, withIntermediateDirectories: true)

        let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        var kept: [String] = []
        var inBlock = false
        for line in existing.components(separatedBy: "\n") {
            if line == excludeBlockStart { inBlock = true; continue }
            if line == excludeBlockEnd { inBlock = false; continue }
            if !inBlock { kept.append(line) }
        }
        while kept.last?.isEmpty == true { kept.removeLast() }

        var output = kept
        if !skills.isEmpty {
            if !output.isEmpty { output.append("") }
            output.append(excludeBlockStart)
            for skill in skills {
                // Leading "/" anchors the pattern to the worktree root.
                output.append("/.agents/skills/\(skill)")
                output.append("/.claude/skills/\(skill)")
            }
            output.append(excludeBlockEnd)
        }
        let text = output.joined(separator: "\n") + "\n"
        if text != existing {
            try? text.write(to: excludeURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Discovery

    private static func repoDirectories(projectRoot: URL) -> [URL] {
        let reposDir = projectRoot.appendingPathComponent("repos", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: reposDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Relative path from directory `dir` to `target` (both standardized).
    static func relativePath(from dir: URL, to target: URL) -> String {
        let fromParts = dir.pathComponents
        let toParts = target.pathComponents
        var common = 0
        while common < min(fromParts.count, toParts.count), fromParts[common] == toParts[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: fromParts.count - common)
        return (ups + toParts[common...]).joined(separator: "/")
    }
}
```

**Correction to apply while writing (the NOTE above):** the exclude entries must be exactly:

```swift
for skill in skills {
    output.append("/.agents/skills/\(skill)")
    output.append("/.claude/skills/\(skill)")
}
```

(leading `/` anchors to the worktree root; the dot stays).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SkillLinkerTests 2>&1 | tail -5`
Expected: `Executed 5 tests, with 0 failures`. If `status --porcelain` shows the links, debug the exclude path — the assertion is the spec; do not weaken it.

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Shell/SkillLinker.swift Tests/DreamuxTests/SkillLinkerTests.swift
git commit -m "Add SkillLinker fan-out with managed git excludes"
```

---

### Task 6: Reconcile on worktree creation (FeatureProvisioner hook)

**Files:**
- Modify: `Sources/Dreamux/Shell/FeatureProvisioner.swift` (provision: after `writeReadme(...)` around line 101; ensureFeatureDirectory: after `writeReadme(...)` around line 189)
- Test: `Tests/DreamuxTests/SkillLinkerTests.swift` (add one test)

- [ ] **Step 1: Write the failing test** (append to `SkillLinkerTests`)

```swift
    func testProvisionLinksProjectSkillsIntoNewWorktree() async throws {
        try installCanonicalSkill("foo")
        // No explicit reconcile: provisioning itself must wire the links.
        _ = try await FeatureProvisioner.provision(
            featureName: "feature-y", in: project, across: [alpha])

        let worktree = alpha.rootURL.appendingPathComponent("feature-y", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent(".agents/skills/foo/SKILL.md").path))
        let status = try await GitOperations.runGit(["status", "--porcelain"], in: worktree)
        XCTAssertEqual(status.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SkillLinkerTests.testProvisionLinksProjectSkillsIntoNewWorktree 2>&1 | tail -5`
Expected: FAIL — the `.agents/skills/foo/SKILL.md` assertion (provision doesn't link yet)

- [ ] **Step 3: Implement the hook**

In `provision(...)`, change:

```swift
        writeReadme(in: featureDir, featureName: featureName, repos: provisionedRepos)
        return featureDir
```

to:

```swift
        writeReadme(in: featureDir, featureName: featureName, repos: provisionedRepos)
        // New worktrees must see project-scope skills immediately —
        // discovery stops at the repo root, so links are the bridge.
        SkillLinker.reconcile(projectRoot: project.rootPath)
        return featureDir
```

In `ensureFeatureDirectory(...)`, change:

```swift
        writeReadme(in: featureDir, featureName: featureName, repos: repos)
        return featureDir
```

to:

```swift
        writeReadme(in: featureDir, featureName: featureName, repos: repos)
        SkillLinker.reconcile(projectRoot: project.rootPath)
        return featureDir
```

- [ ] **Step 4: Run tests to verify they pass (including the existing provisioner suite)**

Run: `swift test --filter SkillLinkerTests 2>&1 | tail -5` then `swift test --filter FeatureProvisionerTests 2>&1 | tail -5`
Expected: both `0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Shell/FeatureProvisioner.swift Tests/DreamuxTests/SkillLinkerTests.swift
git commit -m "Reconcile skill links when feature worktrees are provisioned"
```

---

### Task 7: SkillPreviewCache

**Files:**
- Create: `Sources/Dreamux/Shell/SkillPreviewCache.swift`
- Test: `Tests/DreamuxTests/SkillPreviewCacheTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Dreamux

/// Preview-cache tests against a local fixture "GitHub": a committed
/// repo under <sandbox>/remotes/<owner>/<repo>, reached by pointing
/// DREAMUX_SKILLS_GIT_BASE at the remotes dir. Real git, no network.
@MainActor
final class SkillPreviewCacheTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var cacheRoot: URL!

    override func setUp() async throws {
        setenv("GIT_AUTHOR_NAME", "Dreamux Tests", 1)
        setenv("GIT_AUTHOR_EMAIL", "tests@dreamux.local", 1)
        setenv("GIT_COMMITTER_NAME", "Dreamux Tests", 1)
        setenv("GIT_COMMITTER_EMAIL", "tests@dreamux.local", 1)
        sandbox = try TestSandbox()
        let remotes = sandbox.root.appendingPathComponent("remotes", isDirectory: true)
        try await GitFixtures.makeCommittedRepo(
            at: remotes.appendingPathComponent("acme/agent-skills", isDirectory: true),
            files: [
                "skills/foo/SKILL.md": "---\nname: foo\n---\nfoo body\n",
                "skills/foo/rules/extra.md": "extra\n",
                "skills/bar/SKILL.md": "---\nname: bar\n---\nbar body\n",
                "README.md": "not a skill file\n",
            ])
        cacheRoot = sandbox.root.appendingPathComponent("cache", isDirectory: true)
        setenv("DREAMUX_SKILLS_GIT_BASE", remotes.path + "/", 1)
        setenv("DREAMUX_SKILLS_CACHE_DIR", cacheRoot.path, 1)
    }

    override func tearDown() async throws {
        unsetenv("DREAMUX_SKILLS_GIT_BASE")
        unsetenv("DREAMUX_SKILLS_CACHE_DIR")
        sandbox?.destroy()
        sandbox = nil
    }

    func testPreviewFindsSkillDirAndListsFiles() async throws {
        let preview = try await SkillPreviewCache.preview(
            source: "acme/agent-skills", skillName: "foo")
        XCTAssertTrue(preview.skillDirectory.path.hasSuffix("skills/foo"))
        XCTAssertEqual(preview.relativeFiles, ["SKILL.md", "rules/extra.md"])
        let body = try String(
            contentsOf: preview.skillDirectory.appendingPathComponent("SKILL.md"),
            encoding: .utf8)
        XCTAssertTrue(body.contains("foo body"))
    }

    func testSecondPreviewReusesClone() async throws {
        _ = try await SkillPreviewCache.preview(source: "acme/agent-skills", skillName: "foo")
        // Plant a marker inside the cached clone; a re-clone would erase it.
        let cloneDir = cacheRoot.appendingPathComponent("acme__agent-skills", isDirectory: true)
        let marker = cloneDir.appendingPathComponent("MARKER")
        try "still here\n".write(to: marker, atomically: true, encoding: .utf8)

        _ = try await SkillPreviewCache.preview(source: "acme/agent-skills", skillName: "bar")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testUnknownSkillThrows() async {
        do {
            _ = try await SkillPreviewCache.preview(
                source: "acme/agent-skills", skillName: "nope")
            XCTFail("expected skillNotFound")
        } catch SkillPreviewError.skillNotFound(let skill, _) {
            XCTAssertEqual(skill, "nope")
        } catch { XCTFail("unexpected error: \(error)") }
    }

    func testLocalPreviewListsInstalledSkillFiles() throws {
        let dir = sandbox.root.appendingPathComponent("installed/foo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x\n".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let preview = SkillPreviewCache.localPreview(at: dir.path)
        XCTAssertEqual(preview?.relativeFiles, ["SKILL.md"])
    }
}
```

(If `TestSandbox` doesn't expose `root`, use whatever accessor it has — read `Tests/DreamuxTests/Support/TestSandbox.swift` first and adapt the fixture paths, not the production code.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SkillPreviewCacheTests 2>&1 | tail -5`
Expected: compile FAILURE — `cannot find 'SkillPreviewCache' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

enum SkillPreviewError: LocalizedError {
    case skillNotFound(skill: String, source: String)

    var errorDescription: String? {
        switch self {
        case .skillNotFound(let skill, let source):
            return "Couldn't find a skill named “\(skill)” in \(source)."
        }
    }
}

struct SkillPreview: Equatable, Sendable {
    /// Directory holding this skill's SKILL.md (inside the cached clone
    /// for registry skills, the canonical install dir for installed ones).
    let skillDirectory: URL
    /// Files under `skillDirectory` as sorted relative paths.
    let relativeFiles: [String]
}

/// Shallow-clones a skill's source repo so the browser can show the
/// real files before anything is installed. Clones live under
/// `~/Library/Caches/Dreamux/skill-previews/<owner>__<repo>/` and
/// are reused for 24h (preview is a read-only convenience; `add`
/// always fetches fresh through the CLI).
enum SkillPreviewCache {
    static let maxAge: TimeInterval = 24 * 60 * 60

    static var cacheRoot: URL {
        if let override = ProcessInfo.processInfo.environment["DREAMUX_SKILLS_CACHE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let caches = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("Dreamux/skill-previews", isDirectory: true)
    }

    /// `<owner>/<repo>` → clone URL. Default base is GitHub over https;
    /// tests point DREAMUX_SKILLS_GIT_BASE at a local fixtures dir.
    static func cloneURL(source: String) -> String {
        let base = ProcessInfo.processInfo.environment["DREAMUX_SKILLS_GIT_BASE"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? "https://github.com/"
        return base.hasPrefix("http") ? base + source + ".git" : base + source
    }

    static func preview(
        source: String, skillName: String, forceRefresh: Bool = false
    ) async throws -> SkillPreview {
        let cloneDir = try await cachedClone(source: source, force: forceRefresh)
        guard let skillDir = findSkillDirectory(named: skillName, in: cloneDir) else {
            throw SkillPreviewError.skillNotFound(skill: skillName, source: source)
        }
        return SkillPreview(
            skillDirectory: skillDir, relativeFiles: fileList(under: skillDir))
    }

    /// Preview for an already-installed skill — its files are local.
    static func localPreview(at path: String) -> SkillPreview? {
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return SkillPreview(skillDirectory: dir, relativeFiles: fileList(under: dir))
    }

    // MARK: - Internals

    static func cachedClone(source: String, force: Bool) async throws -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let dirName = source.replacingOccurrences(of: "/", with: "__")
        let cloneDir = cacheRoot.appendingPathComponent(dirName, isDirectory: true)

        if fm.fileExists(atPath: cloneDir.path) {
            let modified = (try? cloneDir.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if !force, Date.now.timeIntervalSince(modified) < maxAge {
                return cloneDir
            }
            try? fm.removeItem(at: cloneDir)
        }
        // Shallow: preview only needs the tip's files.
        _ = try await GitOperations.runGit(
            ["clone", "--depth", "1", cloneURL(source: source), cloneDir.path],
            in: cacheRoot)
        return cloneDir
    }

    /// Shallowest directory named `skillName` that contains a SKILL.md;
    /// falls back to the repo root when it is itself a single skill.
    static func findSkillDirectory(named skillName: String, in cloneDir: URL) -> URL? {
        let fm = FileManager.default
        var matches: [URL] = []
        let enumerator = fm.enumerator(
            at: cloneDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]   // also skips .git
        )
        while let url = enumerator?.nextObject() as? URL {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir, url.lastPathComponent == skillName,
                  fm.fileExists(atPath: url.appendingPathComponent("SKILL.md").path)
            else { continue }
            matches.append(url)
        }
        if let best = matches.min(by: { $0.pathComponents.count < $1.pathComponents.count }) {
            return best
        }
        if fm.fileExists(atPath: cloneDir.appendingPathComponent("SKILL.md").path) {
            return cloneDir
        }
        return nil
    }

    static func fileList(under dir: URL) -> [String] {
        let fm = FileManager.default
        var files: [String] = []
        let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let prefix = dir.standardizedFileURL.path + "/"
        while let url = enumerator?.nextObject() as? URL {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isFile else { continue }
            files.append(String(url.standardizedFileURL.path.dropFirst(prefix.count)))
        }
        return files.sorted()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SkillPreviewCacheTests 2>&1 | tail -5`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Shell/SkillPreviewCache.swift Tests/DreamuxTests/SkillPreviewCacheTests.swift
git commit -m "Add shallow-clone preview cache for skill files"
```

---

### Task 8: SkillsStore

**Files:**
- Create: `Sources/Dreamux/Models/SkillsStore.swift`
- Test: `Tests/DreamuxTests/SkillsStoreTests.swift`

- [ ] **Step 1: Write the failing test** (drives the store through the fake CLI; search isn't covered here — it's pure `SkillsRegistryClient`, already tested)

```swift
import XCTest
@testable import Dreamux

@MainActor
final class SkillsStoreTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var project: Project!
    private var alpha: Repository!
    private var store: SkillsStore!

    override func setUp() async throws {
        setenv("GIT_AUTHOR_NAME", "Dreamux Tests", 1)
        setenv("GIT_AUTHOR_EMAIL", "tests@dreamux.local", 1)
        setenv("GIT_COMMITTER_NAME", "Dreamux Tests", 1)
        setenv("GIT_COMMITTER_EMAIL", "tests@dreamux.local", 1)
        sandbox = try TestSandbox()
        project = try sandbox.makeProject(named: "proj")
        alpha = try await GitFixtures.makeBareLayoutRepo(
            in: project.rootPath, name: "alpha", files: ["alpha.txt": "a\n"])
        setenv("DREAMUX_SKILLS_BIN", SkillsCLITests.fakeSkillsBin, 1)
        setenv("SKILLS_FAKE_GLOBAL_DIR",
               sandbox.root.appendingPathComponent("fake-global").path, 1)
        store = SkillsStore(scope: .project(project.rootPath))
    }

    override func tearDown() async throws {
        unsetenv("DREAMUX_SKILLS_BIN")
        unsetenv("SKILLS_FAKE_GLOBAL_DIR")
        sandbox?.destroy()
        sandbox = nil
    }

    func testPrepareShortCircuitsNodeWithFakeCLI() async {
        await store.prepare()
        XCTAssertTrue(store.nodeReady, "fake CLI must not require node detection")
    }

    func testInstallRefreshesListAndReconcilesLinks() async throws {
        await store.prepare()
        await store.install(source: "acme/agent-skills", skillName: "foo", extraAgents: [])

        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.installedProject.map(\.name), ["foo"])
        // The store must run the linker after mutating.
        let link = alpha.rootURL.appendingPathComponent("main/.agents/skills/foo/SKILL.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testRemoveCleansListAndLinks() async throws {
        await store.prepare()
        await store.install(source: "acme/agent-skills", skillName: "foo", extraAgents: [])
        let installed = try XCTUnwrap(store.installedProject.first)

        await store.remove(installed)

        XCTAssertNil(store.lastError)
        XCTAssertTrue(store.installedProject.isEmpty)
        let link = alpha.rootURL.appendingPathComponent("main/.agents/skills/foo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
    }

    func testGlobalScopeStoreListsGlobalOnly() async {
        let globalStore = SkillsStore(scope: .global)
        await globalStore.prepare()
        await globalStore.install(source: "acme/agent-skills", skillName: "g1", extraAgents: [])
        XCTAssertEqual(globalStore.installedGlobal.map(\.name), ["g1"])
        XCTAssertTrue(globalStore.installedProject.isEmpty)
    }

    func testCLIFailureSurfacesError() async {
        await store.prepare()
        // The fake fails on unsupported subcommands; simulate by removing
        // a skill that doesn't exist? The fake tolerates that — instead
        // break the CLI path entirely.
        setenv("DREAMUX_SKILLS_BIN", "/nonexistent/skills", 1)
        await store.install(source: "acme/x", skillName: "foo", extraAgents: [])
        XCTAssertNotNil(store.lastError)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SkillsStoreTests 2>&1 | tail -5`
Expected: compile FAILURE — `cannot find 'SkillsStore' in scope`

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import Observation

/// Orchestrates skills.sh state for one scope. Project windows create
/// one with `.project(projectRoot)`; the global Skills window uses
/// `.global`. Search goes to the public registry endpoint, the
/// installed list and every mutation go through `SkillsCLI`, and after
/// each project-scope mutation `SkillLinker` fans links out to the
/// worktrees. Mutations serialize per store (`operationInFlight`); the
/// rare cross-window race on the global scope is left to the CLI's own
/// locking.
@MainActor
@Observable
final class SkillsStore {
    enum NodeStatus: Equatable {
        case unknown, detecting, missing
        case ready(NodeDetector.Resolution)
    }

    enum SearchPhase: Equatable {
        case idle, searching, loaded
        case failed(String)
    }

    let scope: SkillScope

    private(set) var installedProject: [InstalledSkill] = []
    private(set) var installedGlobal: [InstalledSkill] = []
    private(set) var searchResults: [RegistrySkill] = []
    private(set) var searchPhase: SearchPhase = .idle
    private(set) var nodeStatus: NodeStatus = .unknown
    /// Name of the skill being installed/removed/updated, nil when idle.
    private(set) var operationInFlight: String?
    var lastError: String?

    /// Sink for CLI output lines — the project window points this at
    /// its SignalStore so installs are observable like runners are.
    var onLogLine: ((String) -> Void)?

    private let registry: SkillsRegistryClient

    init(scope: SkillScope, registry: SkillsRegistryClient = SkillsRegistryClient()) {
        self.scope = scope
        self.registry = registry
    }

    var projectRoot: URL? {
        if case .project(let url) = scope { return url }
        return nil
    }

    var nodeReady: Bool {
        if case .ready = nodeStatus { return true }
        return false
    }

    /// Detect node (once) and load the installed lists. Cheap to call
    /// from every `onAppear`.
    func prepare() async {
        if case .unknown = nodeStatus {
            nodeStatus = .detecting
            if let override = ProcessInfo.processInfo.environment["DREAMUX_SKILLS_BIN"],
               !override.isEmpty {
                // Fake/override CLI needs no node — keeps tests and e2e
                // independent of the machine's node install.
                nodeStatus = .ready(.init(binDirectory: "", version: "override"))
            } else if let resolution = await NodeDetector.detect() {
                nodeStatus = .ready(resolution)
            } else {
                nodeStatus = .missing
            }
        }
        await refreshInstalled()
    }

    func refreshInstalled() async {
        guard nodeReady else { return }
        if let projectRoot {
            installedProject = (try? await cli.list(scope: .project(projectRoot))) ?? []
        }
        installedGlobal = (try? await cli.list(scope: .global)) ?? []
    }

    /// Run a registry search. The view debounces via `.task(id:)`; a
    /// superseded call lands in CancellationError and changes nothing.
    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searchResults = []
            searchPhase = .idle
            return
        }
        searchPhase = .searching
        do {
            searchResults = try await registry.search(query: trimmed)
            searchPhase = .loaded
        } catch is CancellationError {
            // keep whatever is on screen
        } catch let error as URLError where error.code == .cancelled {
            // ditto — URLSession surfaces cancellation this way
        } catch {
            searchPhase = .failed(error.localizedDescription)
        }
    }

    func install(source: String, skillName: String, extraAgents: [String]) async {
        await mutate(name: skillName) { cli, sink in
            try await cli.add(
                source: source, skills: [skillName],
                extraAgents: extraAgents, scope: self.scope, onLine: sink)
        }
    }

    func remove(_ skill: InstalledSkill) async {
        let target: SkillScope = skill.isGlobal
            ? .global
            : .project(projectRoot ?? scope.workingDirectory)
        await mutate(name: skill.name) { cli, sink in
            try await cli.remove(skills: [skill.name], scope: target, onLine: sink)
        }
    }

    func update(_ skill: InstalledSkill) async {
        let target: SkillScope = skill.isGlobal
            ? .global
            : .project(projectRoot ?? scope.workingDirectory)
        await mutate(name: skill.name) { cli, sink in
            try await cli.update(skills: [skill.name], scope: target, onLine: sink)
        }
    }

    // MARK: - Internals

    private var cli: SkillsCLI {
        if case .ready(let resolution) = nodeStatus {
            return SkillsCLI(nodeBinDirectory:
                resolution.binDirectory.isEmpty ? nil : resolution.binDirectory)
        }
        return SkillsCLI(nodeBinDirectory: nil)
    }

    private func mutate(
        name: String,
        _ body: (SkillsCLI, (@Sendable (String) -> Void)?) async throws -> Void
    ) async {
        guard operationInFlight == nil else { return }
        guard nodeReady else {
            lastError = SkillsCLIError.nodeUnavailable.localizedDescription
            return
        }
        operationInFlight = name
        defer { operationInFlight = nil }

        let log = onLogLine
        let sink: (@Sendable (String) -> Void)? = log.map { log in
            { line in Task { @MainActor in log(line) } }
        }
        do {
            try await body(cli, sink)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refreshInstalled()
        if let projectRoot {
            SkillLinker.reconcile(projectRoot: projectRoot)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SkillsStoreTests 2>&1 | tail -5`
Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/Dreamux/Models/SkillsStore.swift Tests/DreamuxTests/SkillsStoreTests.swift
git commit -m "Add SkillsStore orchestrating registry, CLI, and linker"
```

---

### Task 9: Lift the signals trio to the project window

The Skills section needs the project's `SignalStore`, which `FeaturesDetail` currently creates privately (`ContentView.swift:67-98`). Move `RunConfigStore`/`SignalStore`/`RunnerManager` creation up to `ProjectWindowContents` so both sections share them. Pure refactor — no behavior change.

**Files:**
- Modify: `Sources/Dreamux/Views/ProjectWindow.swift`
- Modify: `Sources/Dreamux/Views/ContentView.swift`

- [ ] **Step 1: Move store creation into `ProjectWindowContents`**

In `ProjectWindow.swift`, extend `ProjectWindowContents`:

```swift
    @State private var store: WorkspaceStore
    @State private var repoStore: RepoStore
    @State private var runConfig: RunConfigStore
    @State private var signals: SignalStore
    @State private var runners: RunnerManager

    init(
        project: Project,
        projects: ProjectStore,
        onSwitchProject: @escaping (UUID) -> Void
    ) {
        self.project = project
        self.projects = projects
        self.onSwitchProject = onSwitchProject
        let store = WorkspaceStore(defaultWorkingDirectory: project.rootPath.path)
        let repoStore = RepoStore(project: project)
        let runConfig = RunConfigStore(project: project)
        let signals = SignalStore()
        let runners = RunnerManager(project: project, signals: signals)
        runners.reload(from: runConfig.rawTOML)
        // URL opens land as a browser tab inside the worktree's own
        // workspace — the running app lives next to the terminals
        // working on it. No matching workspace (e.g. the runner is on
        // the default branch) falls back to the external browser.
        runners.openURLInApp = { [weak store] url, branch, title in
            guard let store,
                  let workspace = store.workspaces.first(where: { $0.name == branch })
            else { return false }
            store.session(for: workspace).openWebTab(url: url, title: title)
            return true
        }
        if E2EMode.isActive {
            runners.openOverride = { _ in }
        }
        _store = State(initialValue: store)
        _repoStore = State(initialValue: repoStore)
        _runConfig = State(initialValue: runConfig)
        _signals = State(initialValue: signals)
        _runners = State(initialValue: runners)
    }
```

Pass them through in `body` (`ContentView(store:repoStore:runConfig:signals:runners:projects:currentProjectID:onSwitchProject:)`) and add to the existing `.onAppear` (next to `registerWindowStores`):

```swift
            E2ERegistry.shared.registerRunStores(
                projectID: project.id,
                runners: runners,
                runConfig: runConfig,
                signals: signals
            )
```

- [ ] **Step 2: Slim down `ContentView` / `FeaturesDetail`**

`ContentView` gains `let runConfig: RunConfigStore`, `let signals: SignalStore`, `let runners: RunnerManager` and forwards them to `FeaturesDetail(store:repoStore:runConfig:signals:runners:)`. `FeaturesDetail` deletes its custom `init` and the three `@State` properties; they become `let runConfig: RunConfigStore`, `let signals: SignalStore`, plus `@Bindable var runners: RunnerManager` if any binding is needed (check usages — `RunSetupView` takes them as plain arguments today). Remove the now-duplicate `registerRunStores` from `FeaturesDetail.onAppear`, keep the `e2eBridge` sidebar-mode plumbing untouched.

- [ ] **Step 3: Build and run the full test suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build succeeds, `0 failures`

- [ ] **Step 4: Commit**

```bash
git add Sources/Dreamux/Views/ProjectWindow.swift Sources/Dreamux/Views/ContentView.swift
git commit -m "Lift run-layer stores to the project window"
```

---

### Task 10: Skills section UI (AppSection, browser, detail)

**Files:**
- Modify: `Sources/Dreamux/Models/AppSection.swift`
- Modify: `Sources/Dreamux/Views/ContentView.swift`
- Create: `Sources/Dreamux/Views/SkillsBrowserView.swift`
- Create: `Sources/Dreamux/Views/SkillDetailView.swift`

No unit tests for SwiftUI views (none exist in this codebase); the e2e scenario in Task 12 exercises them. Steps here are build-verified.

- [ ] **Step 1: Add the section**

`AppSection.swift`:

```swift
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case features
    case skills

    var id: String { rawValue }

    var title: String {
        switch self {
        case .features: return "Features"
        case .skills: return "Skills"
        }
    }

    var symbol: String {
        switch self {
        case .features: return "square.grid.2x2.fill"
        case .skills: return "puzzlepiece.extension.fill"
        }
    }

    var tint: Color {
        switch self {
        case .features: return .accentColor
        case .skills: return .purple
        }
    }
}
```

Note: with two cases, `ContentView`'s `AppSection.allCases.count > 1` check now shows the OuterRail — that's the intended reveal, no change needed there.

- [ ] **Step 2: Wire the section detail in `ContentView`**

```swift
    @ViewBuilder
    private var sectionDetail: some View {
        switch section {
        case .features:
            FeaturesDetail(
                store: store, repoStore: repoStore,
                runConfig: runConfig, signals: signals, runners: runners)
        case .skills:
            SkillsDetail(repoStore: repoStore, signals: signals)
        }
    }
```

And add (in `ContentView.swift`, near `FeaturesDetail`):

```swift
/// Hosts the per-project skills browser. The store is recreated when
/// the section is re-entered (same lifecycle as FeaturesDetail's
/// stores); `prepare()` is cheap and node detection caches per store.
private struct SkillsDetail: View {
    @Bindable var repoStore: RepoStore
    let signals: SignalStore

    @State private var skills: SkillsStore

    init(repoStore: RepoStore, signals: SignalStore) {
        self.repoStore = repoStore
        self.signals = signals
        _skills = State(initialValue:
            SkillsStore(scope: .project(repoStore.project.rootPath)))
    }

    var body: some View {
        SkillsBrowserView(store: skills)
            .onAppear {
                skills.onLogLine = { [weak signals] line in
                    signals?.append(source: "skills", line: line)
                }
                E2ERegistry.shared.registerSkillsStore(
                    projectID: repoStore.project.id, store: skills)
                Task { await skills.prepare() }
            }
    }
}
```

(`registerSkillsStore` doesn't exist until Task 12 — add an empty stub to `E2ERegistry` now: `func registerSkillsStore(projectID: UUID, store: SkillsStore) {}`.)

- [ ] **Step 3: Create `SkillsBrowserView.swift`** (layout option A: installed sidebar + browse main area)

```swift
import SwiftUI

/// Skills browser, layout A from the design spec: a 220pt sidebar
/// always showing what's installed (project + global sections), with
/// the main area for registry search. Selecting anything opens
/// SkillDetailView in place of the browse area.
struct SkillsBrowserView: View {
    @Bindable var store: SkillsStore

    @State private var searchText = ""
    @State private var selection: SkillSelection?

    /// Seeded searches for the topic shelf (design decision #2).
    private static let topics = ["React", "Next.js", "Testing", "Design", "Docs", "Git", "Security"]
    /// Known-good sources pinned on the front page.
    private static let pinnedSources = ["vercel-labs/agent-skills", "anthropics/skills"]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)

            Divider()

            mainArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(
            "Skills operation failed",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    // MARK: - Sidebar (installed = management)

    private var sidebar: some View {
        List(selection: Binding(
            get: { selection },
            set: { selection = $0 }
        )) {
            if store.projectRoot != nil {
                Section("Installed — project (\(store.installedProject.count))") {
                    ForEach(store.installedProject) { skill in
                        installedRow(skill)
                            .tag(SkillSelection.installed(skill))
                    }
                }
            }
            Section("Installed — global (\(store.installedGlobal.count))") {
                ForEach(store.installedGlobal) { skill in
                    installedRow(skill)
                        .tag(SkillSelection.installed(skill))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func installedRow(_ skill: InstalledSkill) -> some View {
        HStack {
            Text(skill.name).lineLimit(1)
            Spacer()
            if store.operationInFlight == skill.name {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Main area

    @ViewBuilder
    private var mainArea: some View {
        if let selection {
            SkillDetailView(
                selection: selection,
                store: store,
                onBack: { self.selection = nil }
            )
            .id(selection)
        } else {
            browse
        }
    }

    private var browse: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .missing = store.nodeStatus {
                nodeBanner
            }

            TextField("Search skills.sh…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.topics, id: \.self) { topic in
                        Button(topic) { searchText = topic }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Divider().frame(height: 16)
                    ForEach(Self.pinnedSources, id: \.self) { source in
                        Button(source) { searchText = source.components(separatedBy: "/").last ?? source }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            results
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: searchText) {
            // 300ms debounce: the task is cancelled and restarted on
            // every keystroke; only a pause reaches the search call.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await store.search(query: searchText)
        }
    }

    @ViewBuilder
    private var results: some View {
        switch store.searchPhase {
        case .idle:
            ContentUnavailableView(
                "Search the skills.sh registry",
                systemImage: "puzzlepiece.extension",
                description: Text("Type at least two characters, or pick a topic above.")
            )
        case .searching:
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        case .failed(let message):
            ContentUnavailableView {
                Label("Registry unreachable", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") {
                    Task { await store.search(query: searchText) }
                }
            }
        case .loaded:
            List(store.searchResults, selection: Binding(
                get: { selection },
                set: { selection = $0 }
            )) { skill in
                resultRow(skill)
                    .tag(SkillSelection.registry(skill))
            }
            .listStyle(.inset)
        }
    }

    private func resultRow(_ skill: RegistrySkill) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name).font(.body.weight(.medium))
                Text(skill.source).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isInstalled(skill) {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Text(skill.installs.formatted(.number.notation(.compactName)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func isInstalled(_ skill: RegistrySkill) -> Bool {
        (store.installedProject + store.installedGlobal)
            .contains { $0.name == skill.skillId || $0.name == skill.name }
    }

    private var nodeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Node.js not found — installs are disabled").font(.callout.weight(.medium))
                Text("Install with `brew install node` (or set an asdf/nvm version), then reopen this section. Browsing and preview still work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// What the detail pane is showing: a registry result (preview comes
/// from the clone cache) or an installed skill (files read locally).
enum SkillSelection: Hashable {
    case registry(RegistrySkill)
    case installed(InstalledSkill)
}
```

- [ ] **Step 4: Create `SkillDetailView.swift`**

```swift
import SwiftUI

/// File tree + file preview + actions for one skill. Registry skills
/// preview via SkillPreviewCache (shallow clone); installed skills read
/// their local canonical directory directly. Install always targets
/// claude-code + codex (locked), with optional extra agents.
struct SkillDetailView: View {
    let selection: SkillSelection
    @Bindable var store: SkillsStore
    var onBack: () -> Void

    @State private var preview: SkillPreview?
    @State private var previewError: String?
    @State private var selectedFile: String?
    @State private var fileContents: String = ""
    @State private var extraAgents: Set<String> = []

    private static let optionalAgents = ["cursor", "opencode", "windsurf", "cline"]
    /// Cap what we render so a giant bundled file can't wedge the pane.
    private static let maxPreviewBytes = 200_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: selection) { await loadPreview() }
    }

    // MARK: - Header

    private var titleText: String {
        switch selection {
        case .registry(let skill): return skill.name
        case .installed(let skill): return skill.name
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                Text(titleText).font(.title3.weight(.semibold))
                subtitle
            }
            Spacer()
            actions
        }
        .padding(12)
    }

    @ViewBuilder
    private var subtitle: some View {
        switch selection {
        case .registry(let skill):
            HStack(spacing: 8) {
                Text(skill.source)
                Text("\(skill.installs.formatted(.number.notation(.compactName))) installs")
                if let url = skill.webURL {
                    Link("Open on skills.sh", destination: url)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .installed(let skill):
            Text("\(skill.scope) · \(skill.path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var actions: some View {
        let busy = store.operationInFlight != nil
        switch selection {
        case .registry(let skill):
            Menu {
                ForEach(Self.optionalAgents, id: \.self) { agent in
                    Toggle(agent, isOn: Binding(
                        get: { extraAgents.contains(agent) },
                        set: { on in
                            if on { extraAgents.insert(agent) } else { extraAgents.remove(agent) }
                        }
                    ))
                }
            } label: {
                Text("Agents: claude-code, codex" +
                     (extraAgents.isEmpty ? "" : ", " + extraAgents.sorted().joined(separator: ", ")))
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                Task {
                    await store.install(
                        source: skill.source,
                        skillName: skill.skillId,
                        extraAgents: extraAgents.sorted())
                }
            } label: {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(store.scope.isGlobal ? "Install globally" : "Install to project")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || !store.nodeReady)

        case .installed(let skill):
            Button("Update") { Task { await store.update(skill) } }
                .disabled(busy || !store.nodeReady)
            Button("Remove", role: .destructive) { Task { await store.remove(skill) } }
                .disabled(busy || !store.nodeReady)
        }
    }

    // MARK: - Files

    @ViewBuilder
    private var content: some View {
        if let preview {
            HSplitView {
                List(preview.relativeFiles, id: \.self, selection: $selectedFile) { file in
                    Text(file)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                }
                .frame(minWidth: 180, idealWidth: 240, maxWidth: 360)

                ScrollView {
                    Text(fileContents)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
            }
            .onChange(of: selectedFile) { _, file in
                loadFile(file, from: preview)
            }
        } else if let previewError {
            ContentUnavailableView {
                Label("Preview unavailable", systemImage: "doc.questionmark")
            } description: {
                Text(previewError)
            } actions: {
                if case .registry(let skill) = selection, let url = skill.webURL {
                    Link("Open on skills.sh", destination: url)
                }
                Button("Retry") { Task { await loadPreview(force: true) } }
            }
        } else {
            ProgressView("Fetching files…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadPreview(force: Bool = false) async {
        preview = nil
        previewError = nil
        do {
            switch selection {
            case .registry(let skill):
                preview = try await SkillPreviewCache.preview(
                    source: skill.source, skillName: skill.skillId, forceRefresh: force)
            case .installed(let skill):
                preview = SkillPreviewCache.localPreview(at: skill.path)
                if preview == nil {
                    previewError = "The installed files at \(skill.path) are missing."
                }
            }
            // SKILL.md first — it's the skill's own description.
            selectedFile = preview?.relativeFiles.first { $0 == "SKILL.md" }
                ?? preview?.relativeFiles.first
            if let preview { loadFile(selectedFile, from: preview) }
        } catch {
            previewError = error.localizedDescription
        }
    }

    private func loadFile(_ relative: String?, from preview: SkillPreview) {
        guard let relative else {
            fileContents = ""
            return
        }
        let url = preview.skillDirectory.appendingPathComponent(relative)
        guard let data = try? Data(contentsOf: url) else {
            fileContents = "(couldn't read \(relative))"
            return
        }
        let clipped = data.prefix(Self.maxPreviewBytes)
        fileContents = String(data: clipped, encoding: .utf8)
            ?? "(binary file, \(data.count) bytes)"
        if data.count > Self.maxPreviewBytes {
            fileContents += "\n\n… truncated (\(data.count) bytes total)"
        }
    }
}
```

- [ ] **Step 5: Build, then sanity-run the app**

Run: `swift build 2>&1 | tail -3`
Expected: success. Then launch via the project's usual run path and click the new Skills tile: search "react", open a result, see files, confirm the node banner logic matches your machine. (On this machine bare `npx` is broken — the detector should still find `~/.asdf/installs/nodejs/*/bin`.)

- [ ] **Step 6: Commit**

```bash
git add Sources/Dreamux/Models/AppSection.swift Sources/Dreamux/Views/ContentView.swift Sources/Dreamux/Views/SkillsBrowserView.swift Sources/Dreamux/Views/SkillDetailView.swift Sources/Dreamux/E2E/E2ERegistry.swift
git commit -m "Add Skills section with registry browser and file preview"
```

---

### Task 11: Global Skills window + Home entry point

**Files:**
- Modify: `Sources/Dreamux/DreamuxApp.swift`
- Modify: `Sources/Dreamux/Views/HomeView.swift` (header, `HomeView.swift:83-107`)

- [ ] **Step 1: Add the window scene**

In `DreamuxApp.body`, after the `Window("Dreamux", id: "home")` scene:

```swift
        Window("Skills", id: "global-skills") {
            GlobalSkillsWindow()
                .frame(minWidth: 720, minHeight: 460)
        }
```

And at file scope (near `MissingProjectView`):

```swift
// MARK: - Global skills window

/// App-level skills browser in `.global` scope — same UI as the
/// per-project section, minus the project column and the linker.
private struct GlobalSkillsWindow: View {
    @State private var store = SkillsStore(scope: .global)

    var body: some View {
        SkillsBrowserView(store: store)
            .onAppear {
                E2ERegistry.shared.registerGlobalSkillsStore(store)
                Task { await store.prepare() }
            }
    }
}
```

(Stub `registerGlobalSkillsStore(_:)` on `E2ERegistry` now; Task 12 fills it in.)

- [ ] **Step 2: Add the Home button**

In `HomeView`'s `header` (after the Refresh button, before New Project):

```swift
            Button {
                openWindow(id: "global-skills")
            } label: {
                Label("Skills", systemImage: "puzzlepiece.extension")
            }
            .buttonStyle(.bordered)
            .help("Browse and install agent skills from skills.sh")
```

`HomeView` needs `@Environment(\.openWindow) private var openWindow` if not already present (check the top of the struct).

- [ ] **Step 3: Build and sanity-check**

Run: `swift build 2>&1 | tail -3`
Expected: success. Launch, click Skills on Home → global window opens, lists global installs.

- [ ] **Step 4: Commit**

```bash
git add Sources/Dreamux/DreamuxApp.swift Sources/Dreamux/Views/HomeView.swift Sources/Dreamux/E2E/E2ERegistry.swift
git commit -m "Add global Skills window reachable from Home"
```

---

### Task 12: E2E — registry, commands, stub API, scenario

**Files:**
- Modify: `Sources/Dreamux/E2E/E2ERegistry.swift` (real `registerSkillsStore`/`registerGlobalSkillsStore` + bridge field for section switching)
- Modify: `Sources/Dreamux/Views/ContentView.swift` (consume pending section)
- Modify: `Sources/Dreamux/E2E/E2ECommands.swift` (new commands)
- Create: `Scripts/e2e/skills-api-stub.py`
- Modify: `Scripts/e2e/run-e2e.sh`, `Scripts/e2e/driver.py`, `Scripts/e2e/PROTOCOL.md`

Read `E2ERegistry.swift` and `PROTOCOL.md` fully before this task — the bridge/`pendingSidebarMode` pattern there is the template for everything below.

- [ ] **Step 1: Registry + bridge plumbing**

In `E2ERegistry.swift`: replace the Task 10/11 stubs with real storage, mirroring `registerRunStores`:

```swift
    // Skills stores, keyed like the run stores; the global store has
    // no project.
    private(set) var skillsStores: [UUID: SkillsStore] = [:]
    private(set) var globalSkillsStore: SkillsStore?

    func registerSkillsStore(projectID: UUID, store: SkillsStore) {
        guard E2EMode.isActive else { return }
        skillsStores[projectID] = store
    }

    func registerGlobalSkillsStore(_ store: SkillsStore) {
        guard E2EMode.isActive else { return }
        globalSkillsStore = store
    }
```

On `E2EBridge`, add (next to `pendingSidebarMode`):

```swift
    var pendingAppSection: AppSection?
    var currentAppSection: AppSection?
```

In `ContentView`, consume it exactly like `pendingSidebarMode` is consumed in `FeaturesDetail` (`ContentView.swift:127-151`): set `e2eBridge?.currentAppSection = section` in `.onAppear` and `.onChange(of: section)`, and adopt `pendingAppSection` via `.onChange(of: e2eBridge?.pendingAppSection)` + a `consumePendingSectionIfAny()` that clears the bridge field and assigns `section`. `ContentView` needs the same `e2eBridge` computed property `FeaturesDetail` has — it already receives `repoStore`.

- [ ] **Step 2: Commands** (in `E2ECommands.swift`, following the existing helper style — read how `stopFeature` resolves stores and copy that shape)

Add to the dispatch switch:

```swift
        case "setSection":
            return try setSection(request: request)
        case "skillsSearch":
            return try await skillsSearch(request: request)
        case "skillsList":
            return try await skillsList(request: request)
        case "skillsInstall":
            return try await skillsInstall(request: request)
        case "skillsRemove":
            return try await skillsRemove(request: request)
```

And the handlers (adapt the project/store resolution helpers to the file's existing ones — there will be an equivalent of `bridge(forProject:)`/UUID parsing already):

```swift
    private static func setSection(request: [String: Any]) throws -> [String: Any] {
        let projectID = try projectID(from: request)
        guard let bridge = E2ERegistry.shared.bridge(forProject: projectID) else {
            throw CommandError(message: "no window registered for project \(projectID)")
        }
        guard let raw = request["section"] as? String,
              let section = AppSection(rawValue: raw) else {
            throw CommandError(message: "section must be one of: features, skills")
        }
        bridge.pendingAppSection = section
        return ["ok": true]
    }

    private static func skillsStore(from request: [String: Any]) throws -> SkillsStore {
        if request["global"] as? Bool == true {
            guard let store = E2ERegistry.shared.globalSkillsStore else {
                throw CommandError(message: "global skills window not open")
            }
            return store
        }
        let projectID = try projectID(from: request)
        guard let store = E2ERegistry.shared.skillsStores[projectID] else {
            throw CommandError(message: "skills section not open for project \(projectID)")
        }
        return store
    }

    private static func skillsSearch(request: [String: Any]) async throws -> [String: Any] {
        let store = try skillsStore(from: request)
        guard let query = request["query"] as? String else {
            throw CommandError(message: "skillsSearch needs a query")
        }
        await store.search(query: query)
        return [
            "ok": true,
            "results": store.searchResults.map {
                ["id": $0.id, "skillId": $0.skillId, "name": $0.name,
                 "installs": $0.installs, "source": $0.source]
            },
        ]
    }

    private static func skillsList(request: [String: Any]) async throws -> [String: Any] {
        let store = try skillsStore(from: request)
        await store.refreshInstalled()
        func encode(_ skills: [InstalledSkill]) -> [[String: Any]] {
            skills.map { ["name": $0.name, "path": $0.path, "scope": $0.scope] }
        }
        return ["ok": true,
                "project": encode(store.installedProject),
                "global": encode(store.installedGlobal)]
    }

    private static func skillsInstall(request: [String: Any]) async throws -> [String: Any] {
        let store = try skillsStore(from: request)
        guard let source = request["source"] as? String,
              let skill = request["skill"] as? String else {
            throw CommandError(message: "skillsInstall needs source and skill")
        }
        let extras = request["extraAgents"] as? [String] ?? []
        await store.install(source: source, skillName: skill, extraAgents: extras)
        if let error = store.lastError {
            throw CommandError(message: error)
        }
        return ["ok": true]
    }

    private static func skillsRemove(request: [String: Any]) async throws -> [String: Any] {
        let store = try skillsStore(from: request)
        guard let name = request["skill"] as? String else {
            throw CommandError(message: "skillsRemove needs a skill")
        }
        await store.refreshInstalled()
        guard let installed = (store.installedProject + store.installedGlobal)
            .first(where: { $0.name == name }) else {
            throw CommandError(message: "skill \(name) is not installed")
        }
        await store.remove(installed)
        if let error = store.lastError {
            throw CommandError(message: error)
        }
        return ["ok": true]
    }
```

(`projectID(from:)` — use the file's existing request→UUID helper, whatever it's named.)

- [ ] **Step 3: Stub API server** — `Scripts/e2e/skills-api-stub.py`:

```python
#!/usr/bin/env python3
"""Canned skills.sh search API for e2e runs.

Serves GET /api/search?q=<query>&limit=<n> with a fixed result set
filtered by substring match, mimicking the public endpoint's shape.
Port is given by argv[1]; run-e2e.sh exports the resulting base URL as
DREAMUX_SKILLS_API_BASE.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

SKILLS = [
    {"id": "acme/agent-skills/react-best-practices",
     "skillId": "react-best-practices", "name": "react-best-practices",
     "installs": 1000, "source": "acme/agent-skills"},
    {"id": "acme/agent-skills/testing-guide",
     "skillId": "testing-guide", "name": "testing-guide",
     "installs": 500, "source": "acme/agent-skills"},
]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path != "/api/search":
            self.send_error(404)
            return
        query = parse_qs(parsed.query).get("q", [""])[0]
        if len(query) < 2:
            body = {"error": "Query must be at least 2 characters"}
            self.respond(400, body)
            return
        matches = [s for s in SKILLS if query.lower() in s["name"]]
        self.respond(200, {"query": query, "skills": matches, "count": len(matches)})

    def respond(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
```

`chmod +x Scripts/e2e/skills-api-stub.py`

- [ ] **Step 4: Wire `run-e2e.sh`** — read the script first; following its existing patterns: pick a free port, start the stub in the background (kill in the existing cleanup trap), seed a fixture skills repo, and export to the app + driver:

```bash
# skills.sh integration: stub registry API + fake CLI, plus a local
# "GitHub" the preview cache clones from.
SKILLS_API_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 "$SCRIPT_DIR/skills-api-stub.py" "$SKILLS_API_PORT" &
SKILLS_API_PID=$!
export DREAMUX_SKILLS_API_BASE="http://127.0.0.1:$SKILLS_API_PORT"
export DREAMUX_SKILLS_BIN="$REPO/Tests/Fixtures/bin/skills"
export SKILLS_FAKE_GLOBAL_DIR="$E2E_SANDBOX/global-skills"
export DREAMUX_SKILLS_CACHE_DIR="$E2E_SANDBOX/skills-cache"
export DREAMUX_SKILLS_GIT_BASE="$E2E_SEED_DIR/skills-remotes/"
```

and seed `"$E2E_SEED_DIR/skills-remotes/acme/agent-skills"` as a git repo containing `skills/react-best-practices/SKILL.md` + one extra file (same git-init pattern the script uses to seed the sample-app repos). Add `kill $SKILLS_API_PID` to the cleanup trap.

- [ ] **Step 5: Driver scenario** — add to `driver.py` (style-match the existing scenarios; insert into `SCENARIOS` after the repos/feature scenario so a feature worktree exists):

```python
def worktree_dirs(project_root):
    """Every git worktree in the project: repos/<repo>/<dir> entries
    that carry a .git pointer file (same rule as Repository.worktrees)."""
    found = []
    repos = os.path.join(project_root, "repos")
    for repo in sorted(os.listdir(repos)) if os.path.isdir(repos) else []:
        repo_dir = os.path.join(repos, repo)
        for entry in sorted(os.listdir(repo_dir)):
            candidate = os.path.join(repo_dir, entry)
            if entry != ".bare" and os.path.isdir(candidate) \
                    and os.path.exists(os.path.join(candidate, ".git")):
                found.append(candidate)
    return found


def scenario_skills(d):
    """Skills section: search the stub registry, install via the fake
    CLI, verify canonical copy + worktree links + clean git status,
    then remove and verify cleanup."""
    project_root = d.project_root  # match the accessor other scenarios use
    d.send(cmd="setSection", projectID=d.project_id, section="skills")
    d.wait_until(lambda: d.send(cmd="skillsList", projectID=d.project_id)["ok"])

    results = d.send(cmd="skillsSearch", projectID=d.project_id, query="react")
    assert [r["skillId"] for r in results["results"]] == ["react-best-practices"], results

    d.send(cmd="skillsInstall", projectID=d.project_id,
           source="acme/agent-skills", skill="react-best-practices")

    canonical = os.path.join(project_root, ".agents/skills/react-best-practices/SKILL.md")
    assert os.path.isfile(canonical), canonical

    listed = d.send(cmd="skillsList", projectID=d.project_id)
    assert [s["name"] for s in listed["project"]] == ["react-best-practices"], listed

    # Links in every worktree (default branch + the feature from the
    # earlier scenario), and zero git noise in each.
    for worktree in worktree_dirs(project_root):   # write this helper: repos/*/<dir with .git file>
        for agent_dir in (".agents", ".claude"):
            link = os.path.join(worktree, agent_dir, "skills/react-best-practices")
            assert os.path.islink(link), link
            assert os.path.isfile(os.path.join(link, "SKILL.md")), link
        status = subprocess.run(["git", "status", "--porcelain"], cwd=worktree,
                                capture_output=True, text=True).stdout.strip()
        assert status == "", "git noise in %s: %r" % (worktree, status)

    d.screenshot("skills-installed")

    d.send(cmd="skillsRemove", projectID=d.project_id, skill="react-best-practices")
    assert not os.path.exists(os.path.join(project_root, ".agents/skills/react-best-practices"))
    for worktree in worktree_dirs(project_root):
        assert not os.path.lexists(
            os.path.join(worktree, ".agents/skills/react-best-practices"))
```

Adapt `d.send`/`d.project_id`/`d.screenshot`/`wait_until` to the driver's actual helper names — read two existing scenarios first and copy their idioms exactly.

- [ ] **Step 6: Document the new commands in `Scripts/e2e/PROTOCOL.md`** — one entry per command (`setSection`, `skillsSearch`, `skillsList`, `skillsInstall`, `skillsRemove`), same format as the existing entries, including the `global: true` variant of the store resolution.

- [ ] **Step 7: Run the e2e suite**

Run: `Scripts/e2e/run-e2e.sh 2>&1 | tail -15`
Expected: all scenarios pass, including `scenario_skills`; screenshot `skills-installed` lands in `$ARTIFACTS`.

- [ ] **Step 8: Commit**

```bash
git add Sources/Dreamux/E2E Sources/Dreamux/Views/ContentView.swift Scripts/e2e Tests/Fixtures/bin/skills
git commit -m "Add skills e2e commands, stub registry API, and scenario"
```

---

### Task 13: Full verification + docs touch-up

- [ ] **Step 1: Full unit/integration suite**

Run: `swift test 2>&1 | tail -5`
Expected: `0 failures`

- [ ] **Step 2: Full e2e suite**

Run: `Scripts/e2e/run-e2e.sh 2>&1 | tail -10`
Expected: exit 0

- [ ] **Step 3: Manual smoke against the real network** (one-time sanity that the stubs match reality)

- Launch the app, open a project → Skills → search "react" → expect real results with install counts.
- Open a result → file preview loads from the real GitHub clone.
- Install one (e.g. `web-design-guidelines` from `vercel-labs/agent-skills`) into a scratch project → verify `<project>/.agents/skills/…` exists, links in worktrees, `git status` clean, Signals shows the CLI lines.
- Remove it again.

- [ ] **Step 4: Commit any fixes, then final commit**

```bash
git add -A Sources Tests Scripts docs
git commit -m "Skills.sh integration: browse, preview, install, manage"
```

---

## Out of scope (per spec)

- `skills init` / `skills use`, the auth-gated v1 API, per-repo install scope, bundling node.
