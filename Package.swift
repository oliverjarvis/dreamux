// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clayspace",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Clayspace", targets: ["Clayspace"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.0.1777879537"),
        // Vendored at vendor/bonsplit so we can patch dropZoneAtEnd to
        // absorb the trailing run-off (see TabBarView.swift).
        .package(path: "vendor/bonsplit"),
    ],
    targets: [
        .executableTarget(
            name: "Clayspace",
            dependencies: [
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                .product(name: "Bonsplit", package: "bonsplit"),
                "ClayspacePTY",
            ],
            path: "Sources/Clayspace",
            exclude: ["Resources/Info.plist"]
        ),
        .target(
            name: "ClayspacePTY",
            path: "Sources/ClayspacePTY",
            publicHeadersPath: "include"
        ),
        // Test targets can depend on executable targets on macOS (Swift
        // 5.5+); `@testable import Clayspace` works because debug builds
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
            name: "ClayspaceTests",
            dependencies: ["Clayspace"],
            path: "Tests/ClayspaceTests",
            exclude: ["Fixtures"]
        ),
    ]
)
