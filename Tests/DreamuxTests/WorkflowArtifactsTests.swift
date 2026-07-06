import XCTest
@testable import Dreamux

final class WorkflowArtifactsTests: XCTestCase {
    func testParsesMetaNameAndPhases() {
        let script = """
        export const meta = {
          name: 'review-changes',
          description: 'Review changed files',
          phases: [
            { title: 'Review', detail: 'x' },
            { title: "Verify" },
          ],
        }
        const x = await agent('...')
        """
        let artifacts = WorkflowRunArtifacts.parse(scriptText: script, runID: "wf_1")
        XCTAssertEqual(artifacts?.name, "review-changes")
        XCTAssertEqual(artifacts?.phases, ["Review", "Verify"])
    }

    func testNoMetaReturnsNil() {
        XCTAssertNil(WorkflowRunArtifacts.parse(scriptText: "const a = 1", runID: "wf_2"))
    }

    func testPhaselessMetaParsesWithEmptyPhases() {
        let script = "export const meta = { name: 'solo', description: 'd' }\n"
        let artifacts = WorkflowRunArtifacts.parse(scriptText: script, runID: "wf_3")
        XCTAssertEqual(artifacts?.name, "solo")
        XCTAssertEqual(artifacts?.phases, [])
    }
}
