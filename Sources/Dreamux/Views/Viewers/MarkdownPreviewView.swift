import SwiftUI
import MarkdownUI

/// Read-only GitHub-flavored markdown: tables, fenced code blocks, and
/// task-list checkboxes (the superpowers plan format). Rendering theme
/// follows the system appearance via MarkdownUI's semantic colors.
struct MarkdownPreviewView: View {
    let text: String

    var body: some View {
        ScrollView {
            Markdown(text)
                .markdownTheme(.gitHub)
                .textSelection(.enabled)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
