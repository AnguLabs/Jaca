import SwiftUI
import AVKit
import AppKit

/// Locates the bundled CA-install tutorial clip (placeholder for now — replace
/// with a Jaca-recorded walkthrough before shipping).
enum TutorialVideo {
    static var url: URL? { Bundle.main.url(forResource: "ca-tutorial", withExtension: "mp4") }
}

/// Inline, muted, auto-playing, looping tutorial video shown directly in the sheet.
/// Backed by AppKit's `AVPlayerView` (via NSViewRepresentable) rather than SwiftUI's
/// `VideoPlayer`, whose AVKit-SwiftUI overlay crashes on metadata init here.
struct TutorialVideoView: View {
    let url: URL
    var body: some View {
        PlayerView(url: url)   // fills whatever frame the caller gives it
    }
}

private struct PlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        let queue = AVQueuePlayer()
        context.coordinator.looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        queue.isMuted = true
        view.player = queue
        queue.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var looper: AVPlayerLooper? }
}
