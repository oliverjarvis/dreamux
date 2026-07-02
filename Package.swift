// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dreamux",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Dreamux", targets: ["Dreamux"]),
    ],
    dependencies: [
        // Upstream deleted the `1.0.1777879537` version tag (the repo was
        // retagged to 1.2.x), so an `exact:` version pin no longer resolves
        // from a clean checkout. Pin the same commit by revision instead —
        // identical bytes, and the GhosttyKit.xcframework binary artifact
        // (keyed by URL + checksum) is unaffected.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", revision: "f10e02dd829271be3e361dcde56a6e33a79fa080"),
        // Vendored at vendor/bonsplit so we can patch dropZoneAtEnd to
        // absorb the trailing run-off (see TabBarView.swift).
        .package(path: "vendor/bonsplit"),
        // Markdown rendering for file tabs and (later) plan/spec docs.
        // GitHub-flavored: tables, fenced code, task-list checkboxes.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "Dreamux",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                .product(name: "Bonsplit", package: "bonsplit"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                "DreamuxPTY",
            ],
            path: "Sources/Dreamux",
            exclude: ["Resources/Info.plist", "Resources/AppIcon.icns"],
            resources: [.copy("Resources/Monaco")]
        ),
        .target(
            name: "DreamuxPTY",
            path: "Sources/DreamuxPTY",
            publicHeadersPath: "include"
        ),
        // Test targets can depend on executable targets on macOS (Swift
        // 5.5+); `@testable import Dreamux` works because debug builds
        // compile with testability enabled. Fixture data (sample apps,
        // the fake `claude` shim) lives in Tests/Fixtures, outside this
        // target's path, so tests reference it by repo-relative path
        // rather than via SwiftPM resources.
        // The in-target Fixtures/ dir (TOML corpus for the parser
        // tests) is excluded rather than bundled: tests load it
        // #filePath-relative, same as the Tests/Fixtures data above,
        // and excluding keeps SwiftPM from warning about unhandled
        // files while preserving exact bytes (CRLF cases, etc.).
        .testTarget(
            name: "DreamuxTests",
            dependencies: ["Dreamux"],
            path: "Tests/DreamuxTests",
            exclude: ["Fixtures"]
        ),
    ]
)
