import XCTest
@testable import Dreamux

final class CSVTableTests: XCTestCase {
    // MARK: - parseRecords

    func testSimpleRecords() {
        XCTAssertEqual(
            CSVTable.parseRecords("a,b,c\n1,2,3\n", delimiter: ","),
            [["a", "b", "c"], ["1", "2", "3"]]
        )
    }

    func testQuotedFieldWithDelimiterNewlineAndEscapedQuote() {
        let text = "name,notes\n\"Doe, Jane\",\"line1\nline2 \"\"quoted\"\"\"\n"
        XCTAssertEqual(
            CSVTable.parseRecords(text, delimiter: ","),
            [["name", "notes"], ["Doe, Jane", "line1\nline2 \"quoted\""]]
        )
    }

    func testCRLFAndFinalLineWithoutNewline() {
        XCTAssertEqual(
            CSVTable.parseRecords("a,b\r\n1,2\r\n3,4", delimiter: ","),
            [["a", "b"], ["1", "2"], ["3", "4"]]
        )
    }

    func testTabDelimiter() {
        XCTAssertEqual(
            CSVTable.parseRecords("a\tb\n1\t2\n", delimiter: "\t"),
            [["a", "b"], ["1", "2"]]
        )
    }

    func testUnterminatedQuoteFails() {
        XCTAssertNil(CSVTable.parseRecords("a,\"broken\n1,2\n", delimiter: ","))
    }

    func testEmptyFieldsSurvive() {
        XCTAssertEqual(
            CSVTable.parseRecords("a,,c\n,,\n", delimiter: ","),
            [["a", "", "c"], ["", "", ""]]
        )
    }

    // MARK: - Header heuristic

    func testHeaderDetectedWhenFirstRowTextAndDataNumeric() {
        let records = [["name", "age"], ["jane", "40"], ["joe", "31"]]
        XCTAssertTrue(CSVTable.looksLikeHeader(records))
    }

    func testNoHeaderWhenFirstRowNumericToo() {
        let records = [["1", "2"], ["3", "4"]]
        XCTAssertFalse(CSVTable.looksLikeHeader(records))
    }

    // MARK: - table(from:)

    func testTableRespectsDisplayLimitAndReportsTruncation() throws {
        var lines = ["col"]
        for i in 0..<50 { lines.append("\(i)") }
        let table = try XCTUnwrap(CSVTable.table(
            from: lines.joined(separator: "\n"),
            delimiter: ",", treatFirstRowAsHeader: nil, displayLimit: 10
        ))
        XCTAssertEqual(table.header, ["col"])
        XCTAssertEqual(table.rows.count, 10)
        XCTAssertEqual(table.totalDataRows, 50)
        XCTAssertTrue(table.isTruncated)
    }

    func testTablePadsRaggedRows() throws {
        let table = try XCTUnwrap(CSVTable.table(
            from: "a,b,c\n1,2\n", delimiter: ",",
            treatFirstRowAsHeader: true, displayLimit: 1000
        ))
        XCTAssertEqual(table.rows, [["1", "2", ""]])
    }

    func testNonTabularContentReturnsNil() {
        // One record, one column — a prose paragraph, not a table.
        XCTAssertNil(CSVTable.table(
            from: "just a sentence with no commas",
            delimiter: ",", treatFirstRowAsHeader: nil, displayLimit: 1000
        ))
    }

    func testExplicitHeaderOverrideBeatsHeuristic() throws {
        let table = try XCTUnwrap(CSVTable.table(
            from: "1,2\n3,4\n", delimiter: ",",
            treatFirstRowAsHeader: true, displayLimit: 1000
        ))
        XCTAssertEqual(table.header, ["1", "2"])
        XCTAssertEqual(table.rows, [["3", "4"]])
    }
}
