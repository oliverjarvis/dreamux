import XCTest
@testable import Clayspace

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
