import Foundation

/// Parsed tabular data for the CSV/TSV table viewer. Parsing is a
/// strict-enough RFC 4180 state machine: quoted fields may contain the
/// delimiter, newlines, and escaped quotes (`""`). Input is already
/// bounded by the editor's 2 MB text cap, so whole-file parsing is fine.
struct CSVTable: Equatable {
    /// Column titles when the first record is (or is forced to be) a
    /// header; nil renders numbered columns.
    var header: [String]?
    /// Data records, padded to a uniform column count, capped at the
    /// display limit.
    var rows: [[String]]
    /// Count of data records before capping.
    var totalDataRows: Int
    var isTruncated: Bool

    /// RFC 4180 records, or nil when a quoted field never terminates.
    static func parseRecords(_ text: String, delimiter: Character) -> [[String]]? {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var i = text.startIndex

        while i < text.endIndex {
            let ch = text[i]
            let scalar = ch.unicodeScalars.first?.value ?? 0

            if inQuotes {
                if ch == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")   // escaped quote
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" && field.isEmpty {
                inQuotes = true
            } else if ch == delimiter {
                record.append(field); field = ""
            } else if scalar == 13 {  // CR
                let next = text.index(after: i)
                if next < text.endIndex, text[next].unicodeScalars.first?.value == 10 {
                    i = next
                }
                record.append(field); field = ""
                records.append(record); record = []
            } else if scalar == 10 {  // LF
                record.append(field); field = ""
                records.append(record); record = []
            } else {
                field.append(ch)
            }
            i = text.index(after: i)
        }
        if inQuotes { return nil }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }

    /// True when the first record reads like column titles: every cell
    /// non-empty and non-numeric, while at least one later cell is
    /// numeric. Deliberately conservative — the view offers a manual
    /// override toggle.
    static func looksLikeHeader(_ records: [[String]]) -> Bool {
        guard let first = records.first, records.count > 1 else { return false }
        let firstIsTextOnly = first.allSatisfy { !$0.isEmpty && Double($0) == nil }
        guard firstIsTextOnly else { return false }
        return records.dropFirst().contains { row in
            row.contains { Double($0) != nil }
        }
    }

    static func table(
        from text: String,
        delimiter: Character,
        treatFirstRowAsHeader: Bool?,
        displayLimit: Int
    ) -> CSVTable? {
        guard var records = parseRecords(text, delimiter: delimiter) else { return nil }
        records.removeAll { $0 == [""] }   // blank lines
        let columnCount = records.map(\.count).max() ?? 0
        // Not tabular: nothing that reads as rows-and-columns.
        guard records.count >= 2 || columnCount >= 2 else { return nil }

        let hasHeader = treatFirstRowAsHeader ?? looksLikeHeader(records)
        let header = hasHeader ? pad(records.removeFirst(), to: columnCount) : nil
        let total = records.count
        let capped = records.prefix(displayLimit).map { pad($0, to: columnCount) }
        return CSVTable(
            header: header,
            rows: Array(capped),
            totalDataRows: total,
            isTruncated: total > displayLimit
        )
    }

    private static func pad(_ row: [String], to count: Int) -> [String] {
        row + Array(repeating: "", count: max(0, count - row.count))
    }
}
