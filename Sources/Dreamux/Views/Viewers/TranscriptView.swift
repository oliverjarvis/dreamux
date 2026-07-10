import SwiftUI
import MarkdownUI

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

// MARK: - Rows

private struct TranscriptRow: View {
    let item: TranscriptItem

    /// Claude coral for the assistant, accent for the user — distinct role
    /// tints without shouting.
    private static let assistantColor = Color(red: 0.85, green: 0.47, blue: 0.30)

    var body: some View {
        switch item.kind {
        case .userText(let text):
            MessageBlock(role: "You", tint: .accentColor, text: text)
        case .assistantText(let text):
            MessageBlock(role: "Claude", tint: Self.assistantColor, text: text)
        case .thinking(let text):
            CollapsibleBlock(icon: "brain", label: "Thinking", tint: .secondary, content: text, mono: false)
        case .toolUse(_, let name, let input):
            CollapsibleBlock(icon: "wrench.and.screwdriver", label: name, tint: .secondary,
                             content: input, mono: true, monoLabel: true)
        case .toolResult(let text, let isError):
            CollapsibleBlock(icon: isError ? "xmark.octagon" : "arrow.turn.down.right",
                             label: isError ? "Error" : "Result",
                             tint: isError ? .red : .secondary, content: text, mono: true, collapsedPreview: true)
        case .summary(let text):
            HStack(spacing: 8) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward").foregroundStyle(.tertiary)
                Text(text).font(.system(size: 13)).italic().foregroundStyle(.secondary)
            }
        case .raw(let text):
            Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A role-headed message with markdown-rendered body.
private struct MessageBlock: View {
    let role: String
    let tint: Color
    let text: String

    private static let theme = Theme.gitHub.text {
        ForegroundColor(.primary)
        FontSize(15)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(role)
                .font(.system(size: 11, weight: .semibold)).kerning(0.6)
                .textCase(.uppercase).foregroundStyle(tint)
            Markdown(text)
                .markdownTheme(Self.theme)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Thinking / tool call / tool result — a collapsible pill-headed block.
private struct CollapsibleBlock: View {
    let icon: String
    let label: String
    let tint: Color
    let content: String
    var mono: Bool = false
    var monoLabel: Bool = false
    /// Show a clamped preview when collapsed (for long tool results).
    var collapsedPreview: Bool = false

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint)
                    Text(label)
                        .font(monoLabel
                              ? .system(size: 13, weight: .semibold, design: .monospaced)
                              : .system(size: 12, weight: .medium))
                        .foregroundStyle(monoLabel ? .primary : tint)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !content.isEmpty, expanded || collapsedPreview {
                Text(expanded ? content : preview)
                    .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((tint == .red ? Color.red : Color.primary).opacity(0.05)))
    }

    private var preview: String {
        let clamped = content.prefix(240)
        return clamped.count < content.count ? clamped + "…" : String(clamped)
    }
}
