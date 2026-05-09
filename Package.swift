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
    ]
)
