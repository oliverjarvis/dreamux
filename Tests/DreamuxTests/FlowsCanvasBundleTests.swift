import CryptoKit
import XCTest
@testable import Dreamux

/// Guards the ONE risk of committing a build artifact: a stale bundle
/// shipping silently. Recomputes the digest of `web/flows-canvas/src` +
/// `package.json` and compares it to the `bundle.hash` the build script
/// wrote — so "edited the TSX, forgot to run Scripts/build-flows-canvas.sh"
/// fails `swift test` rather than reaching a user. Needs no node.
final class FlowsCanvasBundleTests: XCTestCase {

    /// Repo root: this file is <root>/Tests/DreamuxTests/<name>.swift.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var webRoot: URL { repoRoot.appendingPathComponent("web/flows-canvas") }

    private var bundledRoot: URL {
        BundledAssetSchemeHandler.bundledRoot(named: "FlowsCanvas")
    }

    func testCommittedBundleExistsInBundleModule() throws {
        for name in ["index.html", "bundle.js", "bundle.css", "bundle.hash"] {
            let url = bundledRoot.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "missing bundled Flows canvas asset: \(name)")
            let size = (try? Data(contentsOf: url).count) ?? 0
            XCTAssertGreaterThan(size, 0, "\(name) is empty")
        }
    }

    func testIndexHTMLCarriesTheRequiredCSP() throws {
        let html = try String(
            contentsOf: bundledRoot.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(html.contains(
            "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:"),
            "index.html must carry the canvas CSP verbatim")
        // No remote references may creep in — the scheme handler serves
        // only this directory and the CSP forbids everything else anyway.
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
    }

    func testBundleHashMatchesTheCommittedSource() throws {
        let recorded = try String(
            contentsOf: bundledRoot.appendingPathComponent("bundle.hash"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = try Self.sourceDigest(webRoot: webRoot)
        XCTAssertEqual(
            recorded, expected,
            """
            The committed Flows canvas bundle is STALE — web/flows-canvas/src or \
            package.json changed without a rebuild. Run: Scripts/build-flows-canvas.sh
            """)
    }

    /// SHA-256 over `src/**` (regular files) plus `package.json`, sorted
    /// byte-wise by path relative to `web/flows-canvas/`. Per file the
    /// stream carries `<relpath>\n` then the raw bytes then `\n`. Keep in
    /// lockstep with `Scripts/build-flows-canvas.sh`.
    static func sourceDigest(webRoot: URL) throws -> String {
        let fileManager = FileManager.default
        var relativePaths: [String] = ["package.json"]

        let srcRoot = webRoot.appendingPathComponent("src")
        guard let enumerator = fileManager.enumerator(
            at: srcRoot, includingPropertiesForKeys: [.isRegularFileKey])
        else {
            throw XCTSkip("web/flows-canvas/src not found at \(srcRoot.path)")
        }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let full = url.standardizedFileURL.path
            let prefix = webRoot.standardizedFileURL.path + "/"
            guard full.hasPrefix(prefix) else { continue }
            relativePaths.append(String(full.dropFirst(prefix.count)))
        }

        // Byte-wise ascending, matching `LC_ALL=C sort`.
        relativePaths.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }

        var hasher = SHA256()
        for relative in relativePaths {
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data("\n".utf8))
            hasher.update(data: try Data(contentsOf: webRoot.appendingPathComponent(relative)))
            hasher.update(data: Data("\n".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
