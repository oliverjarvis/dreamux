import XCTest
@testable import Dreamux

final class PromptKeystrokeRecipesTests: XCTestCase {
    func testPromptSendWrapsInBracketedPaste() {
        XCTAssertEqual(
            PromptKeystrokeRecipes.promptSend("hi\nthere"),
            "\u{1B}[200~hi\nthere\u{1B}[201~\r")
    }

    func testSingleSelect() {
        XCTAssertEqual(PromptKeystrokeRecipes.selectOption(at: 0), "\r")
        XCTAssertEqual(PromptKeystrokeRecipes.selectOption(at: 2), "\u{1B}[B\u{1B}[B\r")
    }

    func testMultiSelectWalksDownwardOnce() {
        // Toggle options 0 and 2 (cursor starts at 0): space, down×2, space, enter.
        XCTAssertEqual(
            PromptKeystrokeRecipes.selectOptions(at: [2, 0]),
            " \u{1B}[B\u{1B}[B \r")
    }

    func testOtherIsOnePastTheLastOption() {
        // 2 options → Other at index 2: down×2, enter, text, enter.
        XCTAssertEqual(
            PromptKeystrokeRecipes.selectOtherAndType(optionCount: 2, text: "custom"),
            "\u{1B}[B\u{1B}[B\rcustom\r")
    }

    func testPermissionTableShipsEmpty() {
        XCTAssertNil(PromptKeystrokeRecipes.permissionRecipe(
            forNotification: "Claude needs your permission to use Bash"))
    }

    func testInterrupt() {
        XCTAssertEqual(PromptKeystrokeRecipes.interrupt, "\u{1B}")
    }
}
