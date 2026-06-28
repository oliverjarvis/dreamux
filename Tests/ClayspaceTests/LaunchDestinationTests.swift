import XCTest
@testable import Clayspace

/// Covers the pure launch-target resolution (`LaunchDestination.resolve`)
/// and the UserDefaults round-trip behind it (`LastOpenedProject`). The
/// persistence tests use a throwaway suite so they never touch the
/// user's real defaults.
final class LaunchDestinationTests: XCTestCase {
    private func project(_ name: String) -> Project {
        Project(name: name, rootPath: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    // MARK: - resolve

    func testEmptyStoreLandsOnWelcome() {
        XCTAssertEqual(LaunchDestination.resolve(lastOpenedID: nil, projects: []), .welcome)
        XCTAssertEqual(LaunchDestination.resolve(lastOpenedID: UUID(), projects: []), .welcome)
    }

    func testRememberedProjectWins() {
        let projects = [project("a"), project("b")]
        XCTAssertEqual(
            LaunchDestination.resolve(lastOpenedID: projects[1].id, projects: projects),
            .project(projects[1].id)
        )
    }

    func testStaleRememberedIDFallsBackToFirstProject() {
        let projects = [project("a"), project("b")]
        XCTAssertEqual(
            LaunchDestination.resolve(lastOpenedID: UUID(), projects: projects),
            .project(projects[0].id)
        )
    }

    func testNoRememberedIDFallsBackToFirstProject() {
        let projects = [project("a"), project("b")]
        XCTAssertEqual(
            LaunchDestination.resolve(lastOpenedID: nil, projects: projects),
            .project(projects[0].id)
        )
    }

    // MARK: - persistence

    private static let suiteName = "LaunchDestinationTests"

    private func freshDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
        return defaults
    }

    override func tearDown() {
        UserDefaults(suiteName: Self.suiteName)?
            .removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    func testRecordAndLoadRoundTrip() throws {
        let defaults = try freshDefaults()
        let id = UUID()
        LastOpenedProject.record(id, in: defaults)
        XCTAssertEqual(LastOpenedProject.load(from: defaults), id)
    }

    func testLoadReturnsNilWhenUnsetOrGarbage() throws {
        let defaults = try freshDefaults()
        XCTAssertNil(LastOpenedProject.load(from: defaults))
        defaults.set("not-a-uuid", forKey: LastOpenedProject.defaultsKey)
        XCTAssertNil(LastOpenedProject.load(from: defaults))
    }
}
