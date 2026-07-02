import SwiftUI
import AppKit

/// Zoomable image viewer: NSScrollView magnification (pinch + smart
/// zoom) around an NSImageView, with Fit / 100% controls and a zoom
/// readout (updated when a gesture ends). Double-click toggles fit ↔
/// actual size.
struct ImageViewerView: View {
    let fileURL: URL
    @State private var loadState: LoadState = .loading
    @State private var zoomPercent: Int = 100
    @State private var command: ZoomCommand? = nil

    enum ZoomCommand: Equatable { case fit, actualSize }
    enum LoadState { case loading, loaded(NSImage), failed }

    var body: some View {
        switch loadState {
        case .loading:
            Color.clear.task {
                if let image = NSImage(contentsOf: fileURL) {
                    loadState = .loaded(image)
                } else {
                    loadState = .failed
                }
            }
        case .loaded(let image):
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button("Fit") { command = .fit }
                    Button("100%") { command = .actualSize }
                    Text("\(zoomPercent)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(image.size.width))×\(Int(image.size.height))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.bar)
                Divider()
                ZoomableImage(image: image, zoomPercent: $zoomPercent, command: $command)
            }
        case .failed:
            ContentUnavailableView(
                "Can't display \(fileURL.lastPathComponent)",
                systemImage: "photo.badge.exclamationmark",
                description: Text("The image failed to load.")
            )
        }
    }
}

private struct ZoomableImage: NSViewRepresentable {
    let image: NSImage
    @Binding var zoomPercent: Int
    @Binding var command: ImageViewerView.ZoomCommand?

    func makeNSView(context: Context) -> NSScrollView {
        let imageView = NSImageView(image: image)
        imageView.frame = NSRect(origin: .zero, size: image.size)
        imageView.imageScaling = .scaleAxesIndependently

        let scroll = NSScrollView()
        scroll.documentView = imageView
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 20
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor

        let doubleClick = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.didDoubleClick))
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)

        context.coordinator.scrollView = scroll
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.magnificationChanged),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scroll)

        DispatchQueue.main.async { context.coordinator.fit() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let command else { return }
        DispatchQueue.main.async {
            switch command {
            case .fit: context.coordinator.fit()
            case .actualSize: context.coordinator.setMagnification(1.0)
            }
            self.command = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomPercent: $zoomPercent, imageSize: image.size)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        private let zoomPercent: Binding<Int>
        private let imageSize: NSSize
        private var isFit = true

        init(zoomPercent: Binding<Int>, imageSize: NSSize) {
            self.zoomPercent = zoomPercent
            self.imageSize = imageSize
        }

        func fit() {
            guard let scroll = scrollView, let doc = scroll.documentView else { return }
            scroll.magnify(toFit: doc.frame)
            isFit = true
            publish()
        }

        func setMagnification(_ value: CGFloat) {
            guard let scroll = scrollView else { return }
            let center = NSPoint(x: imageSize.width / 2, y: imageSize.height / 2)
            scroll.setMagnification(value, centeredAt: center)
            isFit = false
            publish()
        }

        @objc func didDoubleClick() {
            isFit ? setMagnification(1.0) : fit()
        }

        @objc func magnificationChanged() {
            isFit = false
            publish()
        }

        private func publish() {
            guard let scroll = scrollView else { return }
            zoomPercent.wrappedValue = Int((scroll.magnification * 100).rounded())
        }
    }
}
