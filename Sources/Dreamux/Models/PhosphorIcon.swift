import AppKit
import SwiftUI

/// Phosphor fill-weight icons (phosphoricons.com, MIT), bundled as vector
/// PDFs under Resources/PhosphorIcons — converted from the SVGs in
/// phosphor-icons/swift 2.1.0. The upstream package itself doesn't compile
/// under `swift build` (its asset catalog is only processed by Xcode's
/// build system), so we carry just the icons we use. Add new ones with:
/// `rsvg-convert -f pdf -o <name>.pdf <name>.svg`.
///
/// Icons render black-on-alpha — apply `.renderingMode(.template)` and
/// size with `.frame` at the call site.
enum PhosphorIcon {
    static let airTrafficControlFill = load("air-traffic-control-fill")
    static let appWindowFill = load("app-window-fill")
    static let caretRightFill = load("caret-right-fill")
    static let filesFill = load("files-fill")
    static let folderFill = load("folder-fill")
    static let folderOpenFill = load("folder-open-fill")
    static let gitBranchFill = load("git-branch-fill")
    static let gitForkFill = load("git-fork-fill")
    static let globeFill = load("globe-fill")
    static let plusFill = load("plus-fill")
    static let graphFill = load("graph-fill")
    static let packageFill = load("package-fill")
    static let puzzlePieceFill = load("puzzle-piece-fill")
    static let squaresFourFill = load("squares-four-fill")

    private static func load(_ name: String) -> Image {
        guard let url = Bundle.module.url(
                  forResource: name, withExtension: "pdf",
                  subdirectory: "PhosphorIcons"),
              let nsImage = NSImage(contentsOf: url)
        else {
            assertionFailure("missing bundled Phosphor icon: \(name)")
            return Image(systemName: "questionmark.square.dashed")
        }
        return Image(nsImage: nsImage).resizable()
    }
}
