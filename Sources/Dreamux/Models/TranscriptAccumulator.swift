import Foundation

/// Incremental reader state for a live transcript: feed appended bytes,
/// get the newly parsed items. Buffers a partial trailing line between
/// feeds (splits on the newline byte, so multi-byte UTF-8 inside a line
/// is never torn) and tracks AskUserQuestion tool_use/tool_result
/// pairing — an unanswered one means a question dialog is on screen.
final class TranscriptAccumulator {
    private(set) var items: [TranscriptItem] = []
    private var partial = Data()
    private var openQuestions: [PendingQuestion] = []

    struct PendingQuestion: Equatable, Sendable {
        let toolUseID: String
        let questions: [Question]
        struct Question: Equatable, Sendable {
            let text: String
            let multiSelect: Bool
            let options: [Option]
            struct Option: Equatable, Sendable {
                let label: String
                let description: String
            }
        }
    }

    var pendingQuestion: PendingQuestion? { openQuestions.last }

    @discardableResult
    func feed(_ data: Data) -> [TranscriptItem] {
        partial.append(data)
        guard let lastNewline = partial.lastIndex(of: 0x0A) else { return [] }
        let complete = String(decoding: partial[partial.startIndex...lastNewline], as: UTF8.self)
        partial = Data(partial[partial.index(after: lastNewline)...])
        var newItems: [TranscriptItem] = []
        for line in complete.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)
            trackQuestions(line)
            newItems.append(contentsOf: TranscriptParser.parseLine(line))
        }
        items.append(contentsOf: newItems)
        return newItems
    }

    private func trackQuestions(_ line: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let dict = object as? [String: Any],
              let type = dict["type"] as? String,
              let message = dict["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks {
            switch block["type"] as? String {
            case "tool_use" where type == "assistant":
                guard block["name"] as? String == "AskUserQuestion",
                      let id = block["id"] as? String,
                      let pending = Self.pendingQuestion(from: block["input"], toolUseID: id)
                else { continue }
                openQuestions.append(pending)
            case "tool_result" where type == "user":
                if let id = block["tool_use_id"] as? String {
                    openQuestions.removeAll { $0.toolUseID == id }
                }
            default: break
            }
        }
    }

    private static func pendingQuestion(from input: Any?, toolUseID: String) -> PendingQuestion? {
        guard let input = input as? [String: Any],
              let rawQuestions = input["questions"] as? [[String: Any]] else { return nil }
        let questions = rawQuestions.compactMap { raw -> PendingQuestion.Question? in
            guard let text = raw["question"] as? String else { return nil }
            let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { opt -> PendingQuestion.Question.Option? in
                guard let label = opt["label"] as? String else { return nil }
                return .init(label: label, description: opt["description"] as? String ?? "")
            }
            return .init(text: text, multiSelect: raw["multiSelect"] as? Bool ?? false, options: options)
        }
        guard !questions.isEmpty else { return nil }
        return PendingQuestion(toolUseID: toolUseID, questions: questions)
    }
}
