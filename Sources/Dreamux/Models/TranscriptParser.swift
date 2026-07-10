import Foundation

// MARK: - Model

struct TranscriptItem: Identifiable, Sendable {
    let id = UUID()
    let kind: Kind

    enum Kind: Sendable {
        case userText(String)
        case assistantText(String)
        case thinking(String)
        case toolUse(id: String?, name: String, input: String)     // input = pretty JSON
        case toolResult(text: String, isError: Bool)
        case summary(String)
        case raw(String)                               // unrecognized JSONL line
    }
}

// MARK: - Parser

/// Lenient, `JSONSerialization`-based parse (handles arbitrary tool inputs
/// and pretty-prints them without wrestling Codable over untyped JSON).
enum TranscriptParser {
    private static let skipTypes: Set<String> = [
        "mode", "permission-mode", "file-history-snapshot", "ai-title",
        "last-prompt", "queue-operation", "attachment", "system",
    ]

    /// Parse one JSONL line. Exposed for incremental feeding
    /// (TranscriptAccumulator); `parse` remains the whole-file path.
    static func parseLine(_ line: String) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        let data = Data(line.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return [TranscriptItem(kind: .raw(line))]
        }
        switch dict["type"] as? String {
        case "user": appendMessage(dict["message"] as? [String: Any], isUser: true, into: &items)
        case "assistant": appendMessage(dict["message"] as? [String: Any], isUser: false, into: &items)
        case "summary":
            if let summary = dict["summary"] as? String, !summary.isEmpty {
                items.append(TranscriptItem(kind: .summary(summary)))
            }
        case let type? where skipTypes.contains(type): break
        default: items.append(TranscriptItem(kind: .raw(pretty(dict) ?? line)))
        }
        return items
    }

    static func parse(_ text: String) -> [TranscriptItem] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .flatMap { parseLine(String($0)) }
    }

    private static func appendMessage(_ message: [String: Any]?, isUser: Bool, into items: inout [TranscriptItem]) {
        guard let content = message?["content"] else { return }
        if let text = content as? String {
            appendText(text, isUser: isUser, into: &items)
        } else if let blocks = content as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String { appendText(text, isUser: isUser, into: &items) }
                case "thinking":
                    if let text = block["thinking"] as? String, !isBlank(text) {
                        items.append(TranscriptItem(kind: .thinking(text)))
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"].flatMap(pretty) ?? ""
                    items.append(TranscriptItem(kind: .toolUse(id: block["id"] as? String, name: name, input: input)))
                case "tool_result":
                    items.append(TranscriptItem(kind: .toolResult(
                        text: toolResultText(block["content"]),
                        isError: block["is_error"] as? Bool ?? false)))
                default:
                    break
                }
            }
        }
    }

    private static func appendText(_ text: String, isUser: Bool, into items: inout [TranscriptItem]) {
        guard !isBlank(text) else { return }
        items.append(TranscriptItem(kind: isUser ? .userText(text) : .assistantText(text)))
    }

    private static func toolResultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block in
                block["text"] as? String ?? (block["type"] as? String).map { "[\($0)]" }
            }.joined(separator: "\n")
        }
        return pretty(content) ?? ""
    }

    private static func pretty(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
