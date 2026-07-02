import SwiftUI
import AppKit

/// Virtualized, sortable, read-only table for CSV/TSV file tabs.
/// Sorting compares numerically when both cells parse as Double,
/// lexically otherwise. Header row handling is a toggle backed by the
/// `CSVTable.looksLikeHeader` heuristic.
struct CSVTableView: View {
    let text: String
    let delimiter: Character
    @State private var firstRowIsHeader: Bool? = nil   // nil = heuristic

    private static let displayLimit = 10_000

    var body: some View {
        let table = CSVTable.table(
            from: text,
            delimiter: delimiter,
            treatFirstRowAsHeader: firstRowIsHeader,
            displayLimit: Self.displayLimit
        )
        VStack(spacing: 0) {
            if let table {
                HStack {
                    Toggle("First row is header", isOn: Binding(
                        get: { firstRowIsHeader ?? (table.header != nil) },
                        set: { firstRowIsHeader = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    Spacer()
                    if table.isTruncated {
                        Label(
                            "Showing \(table.rows.count.formatted()) of \(table.totalDataRows.formatted()) rows",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    } else {
                        Text("\(table.totalDataRows.formatted()) rows")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.bar)
                Divider()
                CSVGrid(table: table)
            } else {
                ContentUnavailableView(
                    "Not tabular",
                    systemImage: "tablecells.badge.ellipsis",
                    description: Text("This file didn't parse as delimited data. Use the Text mode to view it.")
                )
            }
        }
    }
}

private struct CSVGrid: NSViewRepresentable {
    let table: CSVTable

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        context.coordinator.install(table: table, into: tableView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tableView = scroll.documentView as? NSTableView else { return }
        context.coordinator.install(table: table, into: tableView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var rows: [[String]] = []
        private var installedShape: (columns: Int, header: [String]?) = (0, nil)

        func install(table: CSVTable, into tableView: NSTableView) {
            rows = table.rows
            let columnCount = table.header?.count ?? table.rows.first?.count ?? 0
            let shape = (columnCount, table.header)
            if shape != installedShape {
                installedShape = shape
                for column in tableView.tableColumns { tableView.removeTableColumn(column) }
                for index in 0..<columnCount {
                    let id = NSUserInterfaceItemIdentifier("col\(index)")
                    let column = NSTableColumn(identifier: id)
                    column.title = table.header?[index] ?? "Column \(index + 1)"
                    column.sortDescriptorPrototype = NSSortDescriptor(
                        key: "\(index)", ascending: true)
                    column.width = 120
                    tableView.addTableColumn(column)
                }
            }
            tableView.reloadData()
        }

        nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
            MainActor.assumeIsolated { rows.count }
        }

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let tableColumn,
                  let index = Int(tableColumn.identifier.rawValue.dropFirst(3)),
                  rows.indices.contains(row),
                  rows[row].indices.contains(index) else { return nil }

            let id = NSUserInterfaceItemIdentifier("cell")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = id
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingTail
                field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = rows[row][index]
            return cell
        }

        func tableView(_ tableView: NSTableView,
                       sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key, let index = Int(key) else { return }
            let ascending = descriptor.ascending
            rows.sort { a, b in
                let lhs = index < a.count ? a[index] : ""
                let rhs = index < b.count ? b[index] : ""
                let result: Bool
                if let ln = Double(lhs), let rn = Double(rhs) {
                    result = ln < rn
                } else {
                    result = lhs.localizedStandardCompare(rhs) == .orderedAscending
                }
                return ascending ? result : !result
            }
            tableView.reloadData()
        }
    }
}
