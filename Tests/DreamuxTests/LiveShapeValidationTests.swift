import XCTest
@testable import Dreamux

/// Semi-live validation: runs the real parsers (`ClaudeSessionRegistryReader`,
/// `ClaudeFlowAdapter`, `SubagentMeta`) against a snapshot of this
/// machine's actual `~/.claude` state, to catch shape drift that
/// synthetic fixtures can't. SKIPPED unless explicitly requested — see
/// `Scripts/e2e/validate-flows-live.sh`, which rsyncs a READ-ONLY copy
/// of `~/.claude/sessions` and `~/.claude/projects` into a sandbox and
/// points `DREAMUX_CLAUDE_HOME` at it before setting
/// `DREAMUX_LIVE_VALIDATION=1` and invoking this filter. Never runs
/// against the live `~/.claude` directly and never prints anything
/// beyond counts (no transcript content, no paths, no payload values).
final class LiveShapeValidationTests: XCTestCase {
    /// A transcript's parse-failure rate must stay well under the rest
    /// of noise (huge pastes tripping the line-size guard, forward-compat
    /// message types) — 20% is the spec's real-data tripwire, not a
    /// tuned constant.
    private static let maxSkipRatio = 0.20

    /// Aggregate for the informational loop pass below: how many
    /// windows a given loop signature would have triggered, and across
    /// how many distinct transcripts (indices, never paths).
    private struct LoopAggregate { var windows = 0; var transcriptIndices: Set<Int> = [] }

    func testRealShapeParsesCleanly() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DREAMUX_LIVE_VALIDATION"] == "1",
            "run via Scripts/e2e/validate-flows-live.sh to validate against real ~/.claude state"
        )
        guard let homePath = ProcessInfo.processInfo.environment["DREAMUX_CLAUDE_HOME"], !homePath.isEmpty else {
            return XCTFail("DREAMUX_LIVE_VALIDATION=1 requires DREAMUX_CLAUDE_HOME to point at the rsync'd copy")
        }
        // Liveness ignored: entries here describe historical registry
        // snapshots, not processes we expect to still be running.
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        let entries = ClaudeSessionRegistryReader(home: home, isAlive: { _ in true }).entries()

        var transcriptsScanned = 0
        var totalLines = 0
        var totalSkipped = 0
        var totalEvents = 0
        var totalSpawns = 0
        var worstSkipRatio = 0.0

        var metasParsed = 0
        var metaParseFailures = 0
        var metasJoined = 0

        // Loop-detector live pass (informational only, no assertions):
        // per transcript, pair each toolStarted's signature with its
        // matching toolFinished via toolUseID (agent-spawn toolUseIDs
        // never got a pending signature, so their results are skipped
        // here exactly as FlowStore skips them from the ring), then
        // slide a LoopDetector.windowSize ring the same way FlowStore's
        // `toolCompletionRings` does and count how many appends would
        // have surfaced a loop badge. Deliberate divergence from
        // FlowStore: the ring here is a bare `[ToolCompletion]` with no
        // toolUseID dedup — this is a single, one-shot pass over each
        // transcript's already-materialized events, so no toolUseID can
        // ever recur (unlike the live tailer, which can replay the same
        // bytes from a zoom re-tail).
        var totalToolCompletions = 0
        var loopWindowsDetected = 0
        var loopsBySignature: [String: LoopAggregate] = [:]

        for (transcriptIndex, entry) in entries.enumerated() {
            let transcriptURL = ClaudeHome.transcriptURL(home: home, cwd: entry.cwd, sessionID: entry.sessionId)
            var spawnedToolUseIDs: Set<String> = []
            if let data = try? Data(contentsOf: transcriptURL), let text = String(data: data, encoding: .utf8) {
                transcriptsScanned += 1
                let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                let (events, skipped) = ClaudeFlowAdapter.transcriptEvents(fromLines: lines)
                totalLines += lines.count
                totalSkipped += skipped
                totalEvents += events.count
                var pendingSignatures: [String: String] = [:]
                var ring: [ToolCompletion] = []
                for event in events {
                    switch event {
                    case let .agentSpawned(toolUseID, _, _, _):
                        totalSpawns += 1
                        spawnedToolUseIDs.insert(toolUseID)
                    case let .toolStarted(toolUseID, tool, summary, _):
                        pendingSignatures[toolUseID] = LoopDetector.signature(tool: tool, summary: summary)
                    case let .toolFinished(toolUseID, isError, at):
                        guard let signature = pendingSignatures.removeValue(forKey: toolUseID) else { continue }
                        totalToolCompletions += 1
                        ring.append(ToolCompletion(signature: signature, isError: isError, at: at))
                        if ring.count > LoopDetector.windowSize {
                            ring.removeFirst(ring.count - LoopDetector.windowSize)
                        }
                        if let loop = LoopDetector.detect(window: ring) {
                            loopWindowsDetected += 1
                            var agg = loopsBySignature[loop.signature] ?? LoopAggregate()
                            agg.windows += 1
                            agg.transcriptIndices.insert(transcriptIndex)
                            loopsBySignature[loop.signature] = agg
                        }
                    }
                }
                if !lines.isEmpty {
                    let ratio = Double(skipped) / Double(lines.count)
                    worstSkipRatio = max(worstSkipRatio, ratio)
                    XCTAssertLessThan(
                        ratio, Self.maxSkipRatio,
                        "skip ratio \(ratio) exceeds \(Self.maxSkipRatio) for a real transcript"
                    )
                }
            }

            // Recursive: real subagents dirs can nest team-workflow metas
            // one level deeper (subagents/workflows/<runID>/agent-*.meta.json),
            // which the live tailer's shallow scan doesn't reach — this
            // validation is deliberately more thorough than production.
            let subagentsDir = ClaudeHome.subagentsDirURL(home: home, cwd: entry.cwd, sessionID: entry.sessionId)
            for url in Self.metaFileURLs(under: subagentsDir) {
                guard let meta = SubagentMeta.parse(url: url) else {
                    metaParseFailures += 1
                    continue
                }
                metasParsed += 1
                if let toolUseID = meta.toolUseID, spawnedToolUseIDs.contains(toolUseID) {
                    metasJoined += 1
                }
            }
        }

        XCTAssertEqual(
            metaParseFailures, 0,
            "\(metaParseFailures) agent-*.meta.json file(s) under real session dirs failed to parse"
        )

        // Summary — counts only, never transcript content, paths, or payloads.
        print("""

        === Live shape validation summary ===
        sessions (registry entries) : \(entries.count)
        transcripts scanned         : \(transcriptsScanned)
        transcript lines            : \(totalLines)
        transcript events           : \(totalEvents)
        agent spawns                : \(totalSpawns)
        lines skipped (parse fail)  : \(totalSkipped)
        worst skip ratio            : \(String(format: "%.1f%%", worstSkipRatio * 100))
        agent metas parsed          : \(metasParsed)
        agent metas joined to spawn : \(metasJoined)
        agent meta parse failures   : \(metaParseFailures)
        ======================================
        """)

        // Informational only — no assertions. Signatures are command
        // first tokens, basename-normalized by `LoopDetector.signature`
        // for any path-invoked command ("Bash:foo", never
        // "Bash:/Users/x/bin/foo"), so they're safe to print verbatim:
        // never a full command, a path, or other content.
        print("""

        === Loop-detector live pass (informational) ===
        tool completions             : \(totalToolCompletions)
        windows that would loop      : \(loopWindowsDetected)
        by signature:
        \(Self.formatLoopAggregates(loopsBySignature))
        ================================================
        """)
    }

    private static func formatLoopAggregates(_ aggregates: [String: LoopAggregate]) -> String {
        guard !aggregates.isEmpty else { return "  (none)" }
        return aggregates
            .sorted { $0.key < $1.key }
            .map { signature, agg in
                "  \(signature) \u{2192} \(agg.windows) window(s) across \(agg.transcriptIndices.count) transcript(s)"
            }
            .joined(separator: "\n")
    }

    private static func metaFileURLs(under dir: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix("agent-") && name.hasSuffix(".meta.json") { result.append(url) }
        }
        return result
    }
}
