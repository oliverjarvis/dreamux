import SwiftUI
import Quartz

/// Read-only Quick Look preview — the system renderer for xlsx sheets,
/// docx pages, presentations, and anything else macOS can preview.
/// Falls back to an unavailable message when QL can't be constructed.
struct QuickLookPreviewView: View {
    let fileURL: URL

    var body: some View {
        if let preview = QLWrapper.make() {
            QLRepresentable(view: preview, fileURL: fileURL)
        } else {
            ContentUnavailableView(
                "No preview available",
                systemImage: "eye.slash",
                description: Text("Quick Look can't preview \(fileURL.lastPathComponent).")
            )
        }
    }
}

private enum QLWrapper {
    @MainActor static func make() -> QLPreviewView? {
        QLPreviewView(frame: .zero, style: .normal)
    }
}

private struct QLRepresentable: NSViewRepresentable {
    let view: QLPreviewView
    let fileURL: URL

    func makeNSView(context: Context) -> QLPreviewView {
        view.previewItem = fileURL as NSURL
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {}

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.close()
    }
}
