import XCTest
@testable import Dreamux

/// Pins the untagged default derivations byte-for-byte and covers the
/// tagged / env-override branches — all pure, no Bundle.main, no real FS.
final class BundleIdentityTests: XCTestCase {
    private let base = "com.dreamux.Dreamux"
    private let tagged = "com.dreamux.Dreamux.dogfood"

    func testBuildTagUntaggedIsNil() {
        XCTAssertNil(BundleIdentity.buildTag(bundleID: base))
    }

    func testBuildTagEmptySuffixIsNil() {
        XCTAssertNil(BundleIdentity.buildTag(bundleID: base + "."))
    }

    func testBuildTagUnrelatedIsNil() {
        XCTAssertNil(BundleIdentity.buildTag(bundleID: "com.example.Other"))
    }

    func testBuildTagTagged() {
        XCTAssertEqual(BundleIdentity.buildTag(bundleID: tagged), "dogfood")
    }

    func testEmitSocketDefaultUntaggedIsExactToday() {
        XCTAssertEqual(
            BundleIdentity.emitSocketPath(env: [:], bundleID: base),
            "/tmp/dreamux-emit-com.dreamux.Dreamux.sock"
        )
    }

    func testEmitSocketDefaultTagged() {
        XCTAssertEqual(
            BundleIdentity.emitSocketPath(env: [:], bundleID: tagged),
            "/tmp/dreamux-emit-com.dreamux.Dreamux.dogfood.sock"
        )
    }

    func testEmitSocketEnvOverrideWins() {
        XCTAssertEqual(
            BundleIdentity.emitSocketPath(env: ["DREAMUX_EMIT_SOCKET": "/tmp/custom.sock"], bundleID: base),
            "/tmp/custom.sock"
        )
    }

    func testEmitSocketEmptyEnvFallsBackToDerived() {
        XCTAssertEqual(
            BundleIdentity.emitSocketPath(env: ["DREAMUX_EMIT_SOCKET": ""], bundleID: base),
            "/tmp/dreamux-emit-com.dreamux.Dreamux.sock"
        )
    }

    func testAppSupportBundleDirUntaggedIsExactToday() {
        let dir = BundleIdentity.appSupportBundleDir(base: URL(fileURLWithPath: "/base"), bundleID: base)
        XCTAssertEqual(dir.path, "/base/com.dreamux.Dreamux")
    }

    func testAppSupportBundleDirTagged() {
        let dir = BundleIdentity.appSupportBundleDir(base: URL(fileURLWithPath: "/base"), bundleID: tagged)
        XCTAssertEqual(dir.path, "/base/com.dreamux.Dreamux.dogfood")
    }

    func testStateDirectoryUntaggedIsLegacyDreamux() {
        let dir = BundleIdentity.stateDirectory(base: URL(fileURLWithPath: "/base"), bundleID: base)
        XCTAssertEqual(dir.path, "/base/Dreamux")
    }

    func testStateDirectoryTaggedUsesBundleIDDir() {
        let dir = BundleIdentity.stateDirectory(base: URL(fileURLWithPath: "/base"), bundleID: tagged)
        XCTAssertEqual(dir.path, "/base/com.dreamux.Dreamux.dogfood")
    }
}
