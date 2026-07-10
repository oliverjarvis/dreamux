import Foundation

/// Finds a subagent's transcript beside its parent session transcript
/// (projects/<slug>/<session-uuid>/subagents/agent-<n>.jsonl), joined
/// via the sidecar meta.json whose `toolUseId` matches the parent
/// transcript's Agent tool_use id.
enum SubagentTranscriptLocator {
    static func transcript(forToolUseID toolUseID: String, parentTranscript: URL) -> URL? {
        let subagents = parentTranscript.deletingPathExtension()
            .appendingPathComponent("subagents")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: subagents, includingPropertiesForKeys: nil) else { return nil }
        for meta in entries where meta.lastPathComponent.hasSuffix(".meta.json") {
            guard let data = try? Data(contentsOf: meta),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  dict["toolUseId"] as? String == toolUseID else { continue }
            let jsonl = meta.deletingLastPathComponent().appendingPathComponent(
                meta.lastPathComponent.replacingOccurrences(of: ".meta.json", with: ".jsonl"))
            return FileManager.default.fileExists(atPath: jsonl.path) ? jsonl : nil
        }
        return nil
    }
}
