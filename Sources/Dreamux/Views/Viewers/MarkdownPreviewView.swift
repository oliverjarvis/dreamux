import SwiftUI
import MarkdownUI

/// Read-only GitHub-flavored markdown: tables, fenced code blocks, and
/// task-list checkboxes (the superpowers plan format).
struct MarkdownPreviewView: View {
    let text: String

    /// The GitHub theme with its base text background cleared. The stock
    /// `.gitHub` theme paints a solid `#18191d` behind every text run
    /// (GitHub's own page color), which hugs the content and reads as a
    /// mismatched card floating on our darker pane. Dropping it lets the
    /// text render straight on the pane; code blocks / blockquotes keep
    /// their own backgrounds. `.primary` tracks light/dark like the stock
    /// theme's near-black/near-white text.
    private static let theme = Theme.gitHub
        .text {
            ForegroundColor(.primary)
            FontSize(16)
        }

    var body: some View {
        ScrollView {
            Markdown(text)
                .markdownTheme(Self.theme)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
