import Foundation

/// Groups a transcript's items into display blocks: runs of consecutive
/// tool activity (tool calls + their results) collapse into one block
/// when they contain two or more calls, so a burst of reads and edits
/// renders as a single compact row instead of a wall of cards. Pure —
/// shared by the live chat face and the static transcript viewer.
enum TranscriptRunGrouper {
    enum Block: Identifiable {
        case single(TranscriptItem)
        /// Two-or-more consecutive tool calls, with their results.
        case toolRun([TranscriptItem])

        /// Keyed off the first item so a live-growing run keeps its
        /// identity (and the view its expansion state) across appends.
        var id: UUID {
            switch self {
            case .single(let item): item.id
            case .toolRun(let items): items[0].id
            }
        }
    }

    static func blocks(from items: [TranscriptItem]) -> [Block] {
        var blocks: [Block] = []
        var run: [TranscriptItem] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            if toolNames(in: run).count >= 2 {
                blocks.append(.toolRun(run))
            } else {
                blocks.append(contentsOf: run.map(Block.single))
            }
            run = []
        }

        for item in items {
            switch item.kind {
            case .toolUse, .toolResult:
                run.append(item)
            default:
                flushRun()
                blocks.append(.single(item))
            }
        }
        flushRun()
        return blocks
    }

    /// Names of the tools called in a run, in call order — the collapsed
    /// header's "Bash, Read, +3".
    static func toolNames(in items: [TranscriptItem]) -> [String] {
        items.compactMap {
            if case .toolUse(_, let name, _) = $0.kind { return name }
            return nil
        }
    }

    /// The trailing call still awaiting its result — drives the
    /// "running Bash…" hint on a live run.
    static func unresolvedTrailingCall(in items: [TranscriptItem]) -> String? {
        guard case .toolUse(_, let name, _)? = items.last?.kind else { return nil }
        return name
    }
}
