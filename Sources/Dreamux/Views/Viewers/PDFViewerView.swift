import SwiftUI
import PDFKit

/// PDF rendering via PDFKit — page navigation, ⌘F find, and zoom come
/// with the view.
struct PDFViewerView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: fileURL)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}
