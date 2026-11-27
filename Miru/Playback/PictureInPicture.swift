#if os(iOS)
import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// The picture-in-picture player: AVPlayer on a layer kept in the player's view (iOS shows
/// picture in picture only from an AVPlayer layer that's on screen). AirPlay video builds on it
/// (`AVAirPlayPlayer`).
@MainActor
class AVPiPPlayer: NSObject, PiPPlayer {
    let player = AVPlayer()
    let layer: AVPlayerLayer
    /// Called when the item plays to its end.
    var onEnd: (() -> Void)?
    private var endObserver: NSObjectProtocol?

    override init() {
        layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        super.init()
        player.appliesMediaSelectionCriteriaAutomatically = false
        #if DEBUG
        // UI tests and recordings (`UITEST_MUTE=1`): silent from the start, like mpv.
        if ProcessInfo.processInfo.environment["UITEST_MUTE"] != nil { player.volume = 0 }
        #endif
    }

    func prepare(_ source: PiPSource, at time: Double) async -> Bool {
        let asset = AVURLAsset(url: source.url, options: source.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": source.headers])
        // The asset's playability first (for a stream: its playlist), as Apple recommends.
        guard (try? await asset.load(.isPlayable)) == true, !Task.isCancelled else {
            asset.cancelLoading()
            return false
        }
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        // Ready or failed, whichever comes first; a cancelled start (the hand-off's time is up)
        // stops loading. (Checked every tenth of a second: a KVO observation held only by this
        // wait could go before the item was ready, which a local file hid by being ready at once.)
        while item.status == .unknown, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if Task.isCancelled { item.asset.cancelLoading() }
        let ready = item.status == .readyToPlay
        guard ready, !Task.isCancelled else { return false }
        await item.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero,
                        toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600))
        // The Japanese track the playlist carries (a transcode's, in WebVTT), shown; the
        // playlist may carry the others too (English, for one).
        if let group = try? await asset.loadMediaSelectionGroup(for: .legible),
           let option = group.options.first(where: Self.isJapanese) ?? group.options.first {
            item.select(option, in: group)
        }
        endObserver.map(NotificationCenter.default.removeObserver)
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnd?() }
        }
        return !Task.isCancelled
    }

    /// Jellyfin tags its renditions "jpn" (ISO 639-2); "ja" counts too.
    nonisolated static func isJapanese(_ option: AVMediaSelectionOption) -> Bool {
        let tag = (option.extendedLanguageTag ?? option.locale?.identifier ?? "").lowercased()
        return tag == "ja" || tag == "jpn" || tag.hasPrefix("ja-") || tag.hasPrefix("jpn-")
    }

    func play(rate: Float) {
        player.playImmediately(atRate: rate)
    }

    func pause() { player.pause() }

    var currentTime: Double {
        let time = player.currentTime().seconds
        return time.isFinite ? time : 0
    }

    var isPlaying: Bool { player.rate > 0 }

    func reset() {
        endObserver.map(NotificationCenter.default.removeObserver)
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }
}

/// Picture in picture for the player: holds the AVPlayer side, starts and stops it, and tells
/// the player model when it ends (and whether by "back to the app" or by its ×).
@MainActor
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
    let avPlayer = AVPiPPlayer()
    private(set) lazy var controller: AVPictureInPictureController? = {
        let controller = AVPictureInPictureController(playerLayer: avPlayer.layer)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        return controller
    }()
    /// The engine's own controller, when it runs picture in picture on its own picture
    /// (AetherEngine); otherwise `controller`, on `avPlayer`'s layer.
    private var engineController: AVPictureInPictureController?
    private var active: AVPictureInPictureController? { engineController ?? controller }

    func use(engineController: AVPictureInPictureController?) {
        engineController?.delegate = self
        engineController?.canStartPictureInPictureAutomaticallyFromInline = false
        self.engineController = engineController
    }

    /// Picture in picture ended; `restored`: by its button back to the app (else its ×).
    var onStop: ((_ restored: Bool) -> Void)?
    var onStart: (() -> Void)?
    var onFailure: (() -> Void)?
    private var restoring = false
    private var started = false

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func start() {
        restoring = false
        started = false
        guard let controller = active else { onFailure?(); return }
        // The controller needs a moment after the layer gets its item, and a start asked for
        // too early is dropped without a word (no delegate call): ask again until it opens.
        Task {
            for _ in 0..<10 {
                if controller.isPictureInPicturePossible { controller.startPictureInPicture() }
                try? await Task.sleep(for: .milliseconds(400))
                if controller.isPictureInPictureActive || started { return }
            }
            onFailure?()
        }
    }

    /// Back to the app (its "Back Here", or the episode ending).
    func stop() {
        restoring = true
        active?.stopPictureInPicture()
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { started = true }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            started = true
            onStart?()
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: any Error) {
        MainActor.assumeIsolated { onFailure?() }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated { restoring = true }
        completionHandler(true)
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            let restored = restoring
            restoring = false
            onStop?(restored)
        }
    }
}

/// Shows the AVPlayer layer in the picture's place (picture in picture starts only from a
/// layer that's on screen, and it's the picture until the small window takes it).
struct PiPLayerHost: UIViewRepresentable {
    let layer: AVPlayerLayer

    final class Host: UIView {
        var playerLayer: AVPlayerLayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer?.frame = bounds
        }
    }

    func makeUIView(context: Context) -> Host {
        let view = Host()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.playerLayer = layer
        view.layer.addSublayer(layer)
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: Host, context: Context) {}
}
#endif
