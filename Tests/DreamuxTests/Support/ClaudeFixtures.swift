import Foundation

/// Redacted slices of a real claude session (structure-true, content
/// scrubbed by Scripts/redact-claude-fixture.py). The real fan-out these
/// came from: a session that spawned multiple named Agent tool calls.
enum ClaudeFixtures {
    static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()             // Support
            .deletingLastPathComponent()             // DreamuxTests
            .appendingPathComponent("Fixtures/claude-session", isDirectory: true)
    }

    static func transcriptLines() throws -> [String] {
        try String(contentsOf: fixturesRoot.appendingPathComponent("transcript.jsonl"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    static func subagentMetaURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: fixturesRoot.appendingPathComponent("subagents"), includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".meta.json") }.sorted { $0.path < $1.path }
    }

    static func agentTranscriptLines() throws -> [String] {
        try String(contentsOf: fixturesRoot.appendingPathComponent("subagents/agent-sample.jsonl"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }
}
