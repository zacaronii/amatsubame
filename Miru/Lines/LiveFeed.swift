import AppCommon
import Core
import JellyfinKit
import Lookup
import SwiftUI

/// Holds the live feed still while a finger or pointer is on it (and briefly after), so a
/// tap never lands on a line that's moving.
struct FeedHold: Equatable {
    static let linger: TimeInterval = 1.5
    private(set) var touching = false
    private(set) var until = Date.distantPast

    mutating func touch() {
        touching = true
    }

    mutating func release(at date: Date) {
        touching = false
        until = date.addingTimeInterval(Self.linger)
    }

    func isHeld(at date: Date) -> Bool {
        touching || date < until
    }
}

/// Another device playing something from a visible library ("Watching Now" in Lines).
struct LiveRoute: Hashable {
    var sessionId: String
}

/// Polls Jellyfin for other devices playing something, keeping those from visible libraries.
@MainActor @Observable
final class LiveSessionsModel {
    private(set) var sessions: [JellyfinSession] = []
    @ObservationIgnored private let environment: PlayerEnvironment
    /// Library per series (or movie), so each show's ancestors are looked up once.
    @ObservationIgnored private var libraries: [String: String] = [:]
    static let interval: Duration = .seconds(10)

    init(environment: PlayerEnvironment) {
        self.environment = environment
    }

    /// Runs until the task is cancelled (the Lines tab goes away).
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.interval)
        }
    }

    func refresh() async {
        guard let client = environment.jellyfinClient(), let all = try? await client.sessions() else {
            sessions = []
            return
        }
        var visible: [JellyfinSession] = []
        for session in all {
            guard let item = session.nowPlayingItem else { continue }
            let key = item.seriesId ?? item.id
            if libraries[key] == nil, let library = try? await client.libraryId(of: item.id) {
                libraries[key] = library
            }
            if let library = libraries[key], !environment.hiddenLibraries.contains(library) {
                visible.append(session)
            }
        }
        sessions = visible
    }
}

/// Follows another device's playback: its Japanese subtitles, the line playing now,
/// lookups that pause that device, and mining from the line.
@MainActor @Observable
final class LiveFeedModel {
    enum Status: Equatable {
        case connecting, following, ended
    }

    private(set) var session: JellyfinSession?
    private(set) var status = Status.connecting
    private(set) var transcript: TranscriptModel?
    /// The position now (advanced locally between polls).
    private(set) var position: Double = 0
    var follows = true
    private(set) var message: String?
    /// The line the feed should scroll to (set when following and not held).
    private(set) var scrollTarget: Int?
    var hold = FeedHold()
    @ObservationIgnored private var clock = LiveClock()

    let sessionId: String
    @ObservationIgnored private let environment: PlayerEnvironment
    static let pollInterval: Duration = .seconds(2)

    init(sessionId: String, environment: PlayerEnvironment) {
        self.sessionId = sessionId
        self.environment = environment
    }

    /// The index in `transcript.lines` of the line playing (the last one started).
    var currentIndex: Int? {
        guard let lines = transcript?.lines, !lines.isEmpty else { return nil }
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].start <= position { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }

    var canControl: Bool { session?.supportsRemoteControl == true }

    /// Polls the session and ticks the clock until cancelled.
    func run() async {
        async let polling: Void = poll()
        async let ticking: Void = tick()
        _ = await (polling, ticking)
    }

    private func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    private func tick() async {
        while !Task.isCancelled {
            if session != nil { position = clampedPosition(at: Date()) }
            updateScrollTarget()
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Follows the playing line unless the user is touching or pointing at the feed.
    func updateScrollTarget(now: Date = Date()) {
        guard follows, !hold.isHeld(at: now), let index = currentIndex else { return }
        if scrollTarget != index { scrollTarget = index }
    }

    func refresh() async {
        guard let client = environment.jellyfinClient() else { return }
        guard let sessions = try? await client.sessions() else { return }
        guard let current = sessions.first(where: { $0.id == sessionId }), let item = current.nowPlayingItem else {
            // Seen before and now gone: the other device stopped.
            status = session == nil ? .connecting : .ended
            return
        }
        // A new episode on the other device: load its subtitles.
        if transcript?.itemId != item.id {
            let model = TranscriptModel(itemId: item.id, environment: environment)
            transcript = model
            follows = true
            Task { await model.load() }
        }
        session = current
        clock.observe(position: current.reportedPosition, paused: current.isPaused, at: Date())
        position = clampedPosition(at: Date())
        status = .following
    }

    /// Pauses the other device (when it allows it) and looks the word up.
    func tap(_ line: TranscriptLine, characterIndex: Int) {
        guard let transcript, let session else { return }
        follows = false
        if canControl, !session.isPaused { send(.pause) }
        transcript.lookup.lookUp(line.text, characterIndex: characterIndex, key: String(line.cue), context: miningContext(for: line))
    }

    /// The line's audio and a screenshot from the same file the other device plays,
    /// with its audio track.
    func miningContext(for line: TranscriptLine) -> any MiningContext {
        guard let client = environment.jellyfinClient(), let session, let item = session.nowPlayingItem,
              let mediaSourceId = session.playState?.mediaSourceId ?? transcript?.info?.mediaSourceId else {
            return transcript?.miningContext(for: line) ?? TextMiningContext(miscInfo: "")
        }
        return VideoMiningContext(client: client, localFile: environment.downloader.localFile(itemId: item.id), item: item,
                                  mediaSourceId: mediaSourceId, start: line.start, end: line.end, at: position,
                                  audioTrack: session.ffmpegAudioIndex ?? transcript?.info?.audioIndex,
                                  animated: environment.animatedCardPictures)
            ?? TextMiningContext(miscInfo: "")
    }

    /// The clock's position, never past the end.
    private func clampedPosition(at date: Date) -> Double {
        let position = clock.position(at: date)
        return session?.nowPlayingItem?.duration.map { min(position, $0) } ?? position
    }

    func togglePlayback() {
        guard let session else { return }
        send(session.isPaused ? .unpause : .pause)
    }

    /// A live remote-control command: sent directly (a late pause would be wrong), then
    /// reflected locally until the next poll confirms it.
    private func send(_ command: JellyfinPlaystateCommand) {
        guard let client = environment.jellyfinClient(), let session else { return }
        // Reflected at once, so the clock stops or restarts where it is.
        self.session?.playState?.isPaused = command == .pause
        clock.observe(position: clampedPosition(at: Date()), paused: command == .pause, at: Date())
        Task {
            do {
                try await client.sendPlaystate(sessionId: session.id, command)
                message = nil
            } catch {
                message = "Couldn't reach \(session.deviceName ?? "the other device"): \(error.localizedDescription)"
            }
            try? await Task.sleep(for: .milliseconds(600))
            await refresh()
        }
    }
}

struct LiveFeedView: View {
    @Environment(PlayerEnvironment.self) private var environment
    @Environment(CommonEnvironment.self) private var common
    let route: LiveRoute
    @State private var model: LiveFeedModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model?.session?.nowPlayingItem.map(PlaybackSession.title) ?? "Watching Now")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            let model = self.model ?? LiveFeedModel(sessionId: route.sessionId, environment: environment)
            self.model = model
            await model.run()
        }
    }

    private func content(_ model: LiveFeedModel) -> some View {
        VStack(spacing: 0) {
            header(model)
            Divider()
            feedState(model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func feedState(_ model: LiveFeedModel) -> some View {
        Group {
            switch (model.status, model.transcript?.state) {
            case (.ended, _):
                ContentUnavailableView("Playback Ended", systemImage: "tv.slash",
                                       description: Text("\(model.session?.deviceName ?? "The other device") stopped playing."))
            case (_, .ready?):
                feed(model, transcript: model.transcript!)
            case (_, .noJapanese?):
                ContentUnavailableView("No Japanese Subtitles", systemImage: "captions.bubble",
                                       description: Text("Jellyfin has no Japanese text subtitles for this video."))
            case (_, .failed(let message)?):
                ContentUnavailableView("Couldn't Load Subtitles", systemImage: "wifi.exclamationmark", description: Text(message))
            default:
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func header(_ model: LiveFeedModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: model.session?.isPaused == true ? "pause.circle.fill" : "play.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.session?.deviceName ?? "Connecting…")
                    .font(.subheadline.weight(.semibold))
                Text("\(model.session?.isPaused == true ? "Paused" : "Playing") · \(TranscriptView.timestamp(model.position))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if !model.follows {
                Button("Follow", systemImage: "arrow.down.to.line") { model.follows = true }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("live.follow")
            }
            if model.canControl {
                Button(model.session?.isPaused == true ? "Resume" : "Pause",
                       systemImage: model.session?.isPaused == true ? "play.fill" : "pause.fill") {
                    model.togglePlayback()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("live.playPause")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func feed(_ model: LiveFeedModel, transcript: TranscriptModel) -> some View {
        let current = model.currentIndex
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(transcript.lines.enumerated()), id: \.element.cue) { index, line in
                        TranscriptLineRow(line: line, highlighted: transcript.lookup.highlightedRange(for: String(line.cue)),
                                          isEmphasized: index == current, isDimmed: current.map { index > $0 } ?? false) { characterIndex in
                            model.tap(line, characterIndex: characterIndex)
                        }
                        .id(line.cue)
                    }
                }
                .padding()
            }
            .onScrollPhaseChange { _, phase in
                // Scrolling by hand stops following until "Follow" is tapped.
                if phase == .interacting { model.follows = false }
            }
            .onChange(of: model.scrollTarget) { _, index in
                guard let index, transcript.lines.indices.contains(index) else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(transcript.lines[index].cue, anchor: .center)
                }
            }
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active: model.hold.touch()
                case .ended: model.hold.release(at: Date())
                }
            }
            #else
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in model.hold.touch() }
                    .onEnded { _ in model.hold.release(at: Date()) }
            )
            #endif
            .onChange(of: model.follows) { _, follows in
                guard follows, let index = model.currentIndex else { return }
                withAnimation { proxy.scrollTo(transcript.lines[index].cue, anchor: .center) }
            }
        }
        .sheet(item: Binding(get: { transcript.lookup.popup }, set: { if $0 == nil { transcript.lookup.close() } })) { popup in
            LookupPopupView(service: common.lookup, model: popup)
                .overlay(alignment: .topTrailing) {
                    Button { transcript.lookup.close() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .padding(8)
                    .accessibilityLabel("Close dictionary")
                }
                .presentationDetents([.medium, .large])
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 520)
                #endif
        }
    }
}
