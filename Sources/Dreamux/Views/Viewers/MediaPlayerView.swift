import SwiftUI
import AVKit

/// Video/audio playback with native transport controls. AVPlayer
/// streams from disk, so there is no size cap. The player pauses on
/// teardown (tab close); switching workspaces keeps tabs alive by
/// design (`keepAllAlive`), matching web-tab behavior.
struct MediaPlayerView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: fileURL)
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
