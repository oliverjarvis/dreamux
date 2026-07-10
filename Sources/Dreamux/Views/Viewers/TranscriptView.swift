import SwiftUI

/// Renders a `.jsonl` file as a readable conversation rather than raw text.
/// Built for Claude Code session transcripts — user / assistant messages,
/// thinking, tool calls, and tool results — but degrades gracefully for any
/// JSONL: lines it doesn't recognize show as pretty-printed JSON.
struct TranscriptView: View {
    let fileURL: URL

    @State private var items: [TranscriptItem] = []
    @State private var loadState: LoadState = .loading

    private enum LoadState: Equatable { case loading, loaded, failed(String) }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                centered { Text("Reading transcript…").foregroundStyle(.secondary) }
            case .failed(let message):
                centered {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.questionmark").font(.system(size: 30)).foregroundStyle(.tertiary)
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
            case .loaded:
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        header
                        ForEach(items) { TranscriptRow(item: $0) }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: fileURL) { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(.secondary)
            Text("\(items.count) ent\(items.count == 1 ? "ry" : "ries")")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } label: {
                Label("Reveal in Finder", systemImage: "folder").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        loadState = .loading
        let url = fileURL
        let (parsed, errorMessage) = await Task.detached(priority: .userInitiated) { () -> ([TranscriptItem], String?) in
            guard FileManager.default.fileExists(atPath: url.path) else {
                return ([], "No transcript file here — this session didn't write one, or it was cleaned up.")
            }
            guard let data = try? Data(contentsOf: url) else { return ([], "Couldn't read this transcript.") }
            guard data.count < 100 * 1024 * 1024 else { return ([], "This transcript is too large to render.") }
            return (TranscriptParser.parse(String(decoding: data, as: UTF8.self)), nil)
        }.value
        if let errorMessage {
            loadState = .failed(errorMessage)
        } else {
            items = parsed
            loadState = parsed.isEmpty ? .failed("No conversation found in this file.") : .loaded
        }
    }
}
