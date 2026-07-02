import Foundation
import UniformTypeIdentifiers

/// How a file tab renders its content. Decided once at open time from
/// the file's extension (with UTType conformance as fallback). Whether
/// the file is *actually* displayable (binary/oversized text, missing
/// media) is a separate, per-kind check in `FileEditorTabSession`.
enum FileTabKind: String, Sendable {
    case code           // Monaco editor
    case markdown       // rendered MarkdownUI with a Raw (Monaco) toggle
    case image          // native zoomable image viewer
    case video          // AVPlayerView
    case audio          // AVPlayerView
    case pdf            // PDFView
    case officePreview  // QLPreviewView (xlsx, docx, keynote, …), read-only
    case tabular        // CSV/TSV table with a Text (Monaco) toggle

    static func kind(forPathExtension ext: String) -> FileTabKind {
        let lower = ext.lowercased()
        switch lower {
        case "md", "markdown", "mdx":
            return .markdown
        case "csv", "tsv":
            return .tabular
        case "pdf":
            return .pdf
        case "xlsx", "xls", "docx", "doc", "pptx", "ppt",
             "numbers", "pages", "key":
            return .officePreview
        case "svg":
            // UTType reports svg as an image, but be explicit: NSImage
            // renders it natively and we never want Monaco XML mode.
            return .image
        case "":
            return .code
        default:
            break
        }
        guard let type = UTType(filenameExtension: lower) else { return .code }
        if type.conforms(to: .image) { return .image }
        // Order matters: .audio also conforms to .audiovisualContent.
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .pdf) { return .pdf }
        return .code
    }

    /// SF Symbol for the Bonsplit tab chip.
    var tabIcon: String {
        switch self {
        case .code: return "doc.text"
        case .markdown: return "doc.richtext"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.text.image"
        case .officePreview: return "tablecells"
        case .tabular: return "tablecells"
        }
    }

    /// Kinds whose content lives in (or can drop into) the Monaco
    /// editor — these are the only kinds that read text and can be
    /// dirty/saved.
    var isMonacoBacked: Bool {
        switch self {
        case .code, .markdown, .tabular: return true
        case .image, .video, .audio, .pdf, .officePreview: return false
        }
    }
}
