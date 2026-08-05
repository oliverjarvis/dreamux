// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dreamux",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Dreamux", targets: ["Dreamux"]),
    ],
    dependencies: [
        // Upstream prunes old `storage.*` release assets over time — the
        // previously pinned revision's GhosttyKit.xcframework.zip 404s now
        // too. Track their current release instead of a fixed revision so
        // this doesn't silently rot again.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.3.2"),
        // Vendored at vendor/bonsplit so we can patch dropZoneAtEnd to
        // absorb the trailing run-off (see TabBarView.swift).
        .package(path: "vendor/bonsplit"),
        // Markdown rendering for file tabs and (later) plan/spec docs.
        // GitHub-flavored: tables, fenced code, task-list checkboxes.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
        // Layered DAG layout for the Flows graph — a pure-Swift port of
        // dagre (network-simplex ranking, barycenter crossing reduction,
        // Brandes-Köpf coordinates, routed edge waypoints). Layout only;
        // FlowLayoutEngine wraps it behind its own interface.
        .package(url: "https://github.com/lukilabs/dagre-swift", from: "0.1.0"),
    ],
    targets: [
        // Must never link XCTest — ProjectSession gates signal persistence on NSClassFromString("XCTestCase") == nil.
        .executableTarget(
            name: "Dreamux",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                .product(name: "Bonsplit", package: "bonsplit"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "SwiftDagre", package: "dagre-swift"),
                "DreamuxPTY",
            ],
            path: "Sources/Dreamux",
            exclude: ["Resources/Info.plist", "Resources/AppIcon.icns"],
            resources: [
                .copy("Resources/Monaco"),
                .copy("Resources/AppletScaffold"),
                .copy("Resources/PhosphorIcons"),
            ]
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
            dependencies: [
                "Dreamux",
                // The raw C API, TEST-ONLY: GhosttyConfigAcceptanceTests
                // loads rendered configs through ghostty_config_load_file
                // and reads ghostty's live defaults with
                // ghostty_config_get, so a libghostty bump that renames a
                // key or moves a default color fails CI instead of
                // silently reverting the user's theme. The app target must
                // NOT gain this dependency — app code reaches ghostty only
                // through GhosttyTerminal's typed wrapper.
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ],
            path: "Tests/DreamuxTests",
            exclude: ["Fixtures"]
        ),
    ]
)
