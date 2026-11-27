#if os(iOS)
import AetherEngine
import AVFoundation
import AVKit
import Combine
import UIKit

/// Spike (never merged): the player for the owner's device test. AetherEngine plays the file and
/// AVKit's own player screen around it gives picture in picture, AirPlay and the controls. The
/// chosen embedded subtitle track's lines are drawn over the picture from the engine's cues, the
/// text Miru would make tappable. A line at the top shows the engine's route and the battery used.
@MainActor
public final class AetherTestPlayerController: UIViewController, AVPlayerViewControllerDelegate {
    private let url: URL
    private let headers: [String: String]
    private let start: Double
    private let engine: AetherEngine
    private let player = AVPlayerViewController()
    private let subtitleLabel = UILabel()
    private let infoLabel = UILabel()
    private let subtitlesButton = UIButton(type: .system)
    private let softwareView = UIView()
    private let surface = AetherPlayerView(frame: .zero)
    private let playPause = UIButton(type: .system)
    private let pipButton = UIButton(type: .system)
    private var softwarePiP: AVPictureInPictureController?
    private var softwarePiPDelegate: SoftwarePiPDelegate?
    private var boundSurface = false
    private var cancellables: Set<AnyCancellable> = []
    private var ticker: Timer?
    private var openedAt = Date()
    private var startBattery: Float = -1
    private var pickedTrack = false
    private var selectedTrack: Int?
    private var failure: String?
    /// Called when the Close button is pressed (the engine has stopped by then).
    public var onClose: (() -> Void)?

    public init(url: URL, headers: [String: String], start: Double) throws {
        self.url = url
        self.headers = headers
        self.start = start
        engine = try AetherEngine()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let close = UIButton(type: .system)
        close.setTitle("Close", for: .normal)
        close.addAction(UIAction { [weak self] _ in self?.close() }, for: .primaryActionTriggered)
        subtitlesButton.setTitle("Subtitles", for: .normal)
        subtitlesButton.showsMenuAsPrimaryAction = true
        infoLabel.font = .preferredFont(forTextStyle: .caption1)
        infoLabel.textColor = .lightGray
        infoLabel.numberOfLines = 2
        infoLabel.adjustsFontSizeToFitWidth = true
        let bar = UIStackView(arrangedSubviews: [close, infoLabel, subtitlesButton])
        bar.spacing = 12
        bar.alignment = .center
        close.setContentHuggingPriority(.required, for: .horizontal)
        subtitlesButton.setContentHuggingPriority(.required, for: .horizontal)
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)

        player.allowsPictureInPicturePlayback = true
        player.canStartPictureInPictureAutomaticallyFromInline = true
        player.delegate = self
        addChild(player)
        player.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(player.view)
        player.didMove(toParent: self)

        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center
        subtitleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        subtitleLabel.shadowColor = .black
        subtitleLabel.shadowOffset = CGSize(width: 1, height: 1)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.isUserInteractionEnabled = false

        // The software route (no AVPlayer): AetherEngine's own surface, simple controls and its PiP.
        softwareView.isHidden = true
        softwareView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(softwareView)
        surface.translatesAutoresizingMaskIntoConstraints = false
        softwareView.addSubview(surface)
        let controls = UIStackView(arrangedSubviews: [
            button("gobackward.10") { [weak self] in self?.skip(-10) },
            playPause,
            button("goforward.10") { [weak self] in self?.skip(10) },
            pipButton,
            AVRoutePickerView(),
        ])
        playPause.addAction(UIAction { [weak self] _ in self?.engine.togglePlayPause() }, for: .primaryActionTriggered)
        pipButton.setImage(UIImage(systemName: "pip.enter"), for: .normal)
        pipButton.addAction(UIAction { [weak self] _ in self?.toggleSoftwarePiP() }, for: .primaryActionTriggered)
        controls.distribution = .equalSpacing
        controls.translatesAutoresizingMaskIntoConstraints = false
        softwareView.addSubview(controls)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: softwareView.topAnchor),
            surface.leadingAnchor.constraint(equalTo: softwareView.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: softwareView.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -8),
            controls.leadingAnchor.constraint(equalTo: softwareView.safeAreaLayoutGuide.leadingAnchor, constant: 40),
            controls.trailingAnchor.constraint(equalTo: softwareView.safeAreaLayoutGuide.trailingAnchor, constant: -40),
            controls.bottomAnchor.constraint(equalTo: softwareView.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            controls.heightAnchor.constraint(equalToConstant: 44),
        ])

        view.addSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            subtitleLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            subtitleLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -90),
            softwareView.topAnchor.constraint(equalTo: player.view.topAnchor),
            softwareView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            softwareView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            softwareView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: guide.topAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            player.view.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            player.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            player.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            player.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        engine.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avPlayer in self?.player.player = avPlayer }
            .store(in: &cancellables)
        engine.$videoRoute
            .receive(on: DispatchQueue.main)
            .sink { [weak self] route in self?.routeChanged(route) }
            .store(in: &cancellables)
        engine.$softwarePiPSource
            .receive(on: DispatchQueue.main)
            .sink { [weak self] source in self?.softwarePiPChanged(source) }
            .store(in: &cancellables)
        engine.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in self?.tracksChanged(tracks) }
            .store(in: &cancellables)

        UIDevice.current.isBatteryMonitoringEnabled = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        Task { await load() }
    }

    private func load() async {
        var options = LoadOptions()
        options.httpHeaders = headers
        // Subtitles AVPlayer draws itself, for the picture-in-picture window and AirPlay.
        options.prepareNativeSubtitles = true
        options.nativeAudioTrackMenu = true
        options.serveIFramePlaylist = true
        // Test runs on the Mac stay silent (UITEST_MUTE), before and after the load.
        let muted = ProcessInfo.processInfo.environment["UITEST_MUTE"] != nil
        if muted { engine.volume = 0 }
        do {
            _ = try await engine.load(url: url, startPosition: start > 0 ? start : nil, options: options)
            if muted { engine.volume = 0 }
            openedAt = Date()
            startBattery = UIDevice.current.batteryLevel
        } catch {
            failure = "Couldn't play: \(error.localizedDescription)"
        }
    }

    /// The first Japanese text track (else the first text track) is shown once the tracks are known.
    private func tracksChanged(_ tracks: [TrackInfo]) {
        let text = tracks.filter { !["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"].contains($0.codec) }
        if !pickedTrack, let first = text.first(where: { ["ja", "jpn"].contains($0.language ?? "") }) ?? text.first {
            pickedTrack = true
            select(first.id)
        }
        var actions = [UIAction(title: "Off", state: selectedTrack == nil ? .on : .off) { [weak self] _ in self?.select(nil) }]
        for track in tracks {
            let name = [track.name, track.language, track.codec].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
            actions.append(UIAction(title: name, state: selectedTrack == track.id ? .on : .off) { [weak self] _ in self?.select(track.id) })
        }
        subtitlesButton.menu = UIMenu(title: "Subtitles drawn by the test player", children: actions)
    }

    private func select(_ id: Int?) {
        selectedTrack = id
        if let id { engine.selectSubtitleTrack(index: id) } else { engine.clearSubtitle() }
        tracksChanged(engine.subtitleTracks)
    }

    private func tick() {
        let time = engine.clock.sourceTime
        let lines = selectedTrack == nil ? [] : engine.subtitleCues.filter { $0.startTime <= time && time < $0.endTime }
        let text = lines.map { cue -> String in
            switch cue.body {
            case .text(let text): text
            case .richText(let runs): runs.map(\.text).joined()
            case .image: ""
            }
        }.joined(separator: "\n")
        if subtitleLabel.text != text { subtitleLabel.text = text }

        var info = "AetherEngine · \(engine.videoRoute.rawValue) · audio \(engine.audioDelivery.rawValue)"
        if let failure { info = failure }
        let level = UIDevice.current.batteryLevel
        if startBattery >= 0, level >= 0 {
            let minutes = Int(Date().timeIntervalSince(openedAt) / 60)
            info += "\nBattery \(Int((startBattery * 100).rounded()))% → \(Int((level * 100).rounded()))% in \(minutes) min"
        }
        if infoLabel.text != info { infoLabel.text = info }
        let symbol = engine.state == .playing ? "pause.fill" : "play.fill"
        if playPause.image(for: .normal) != UIImage(systemName: symbol) { playPause.setImage(UIImage(systemName: symbol), for: .normal) }
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        return button
    }

    private func skip(_ seconds: Double) {
        let target = max(0, engine.clock.sourceTime + seconds)
        Task { await engine.seek(to: target) }
    }

    /// AVKit's screen for the AVPlayer routes; the engine's own surface for the software route.
    private func routeChanged(_ route: VideoRoute) {
        let software = route == .software
        softwareView.isHidden = !software
        player.view.isHidden = software
        if software, !boundSurface {
            boundSurface = true
            engine.bind(view: surface)
        }
    }

    private func softwarePiPChanged(_ source: SoftwarePiPSource?) {
        softwarePiP = source?.makePictureInPictureController()
        let delegate = SoftwarePiPDelegate(engine: engine)
        softwarePiPDelegate = delegate
        softwarePiP?.delegate = delegate
        pipButton.isEnabled = softwarePiP != nil
    }

    private func toggleSoftwarePiP() {
        guard let softwarePiP else { return }
        if softwarePiP.isPictureInPictureActive { softwarePiP.stopPictureInPicture() } else { softwarePiP.startPictureInPicture() }
    }

    private func close() {
        ticker?.invalidate()
        ticker = nil
        player.player = nil
        engine.stop()
        onClose?()
    }

    // MARK: Picture in picture

    public func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        engine.pictureInPictureActive = true
        // Our drawn lines can't reach the window: AVPlayer draws the Japanese rendition there instead.
        if selectedTrack != nil, let native = engine.nativeSubtitleTracks.first(where: { ["ja", "jpn"].contains($0.language ?? "") })
            ?? engine.nativeSubtitleTracks.first {
            engine.setNativeSubtitleSelected(track: native.ordinal)
        }
    }

    public func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        engine.pictureInPictureActive = false
        engine.setNativeSubtitleSelected(track: nil)
    }

    public func playerViewController(_ playerViewController: AVPlayerViewController,
                                     restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // The player screen stays open under the window, so there is nothing to bring back.
        completionHandler(true)
    }
}
/// Reports the software route's picture-in-picture window to the engine (it keeps the pipeline alive
/// and draws the subtitles into the window).
@MainActor
private final class SoftwarePiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
    weak var engine: AetherEngine?

    init(engine: AetherEngine) {
        self.engine = engine
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { engine?.pictureInPictureActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { engine?.pictureInPictureActive = false }
    }
}
#endif
