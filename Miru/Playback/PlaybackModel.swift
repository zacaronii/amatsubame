import AppCommon
import AudiobookshelfKit
import Core
import Foundation
import JellyfinKit
import Lookup
import Observation
import PlayerKit

/// What to play: an item and the episodes after it (for "Next episode").
struct PlaybackSession: Codable, Identifiable, Hashable {
    var itemId: String
    var title: String
    var following: [String] = []
    /// Start here instead of the resume point ("Play from here" in Lines).
    var startAt: Double?

    var id: String { itemId }

    init(item: JellyfinItem, following: [String] = []) {
        itemId = item.id
        title = Self.title(item)
        self.following = following
    }

    static func title(_ item: JellyfinItem) -> String {
        [item.seriesName, item.episodeLabel, item.name].compactMap(\.self).joined(separator: " · ")
    }
}

extension Notification.Name {
    /// Posted when the player closes so lists can refresh progress.
    static let playbackDidClose = Notification.Name("playbackDidClose")
    /// Posted (object: the item id) once Jellyfin has a subtitle file the user saved there.
    static let localSubtitleUploaded = Notification.Name("localSubtitleUploaded")
}

/// Plays one Jellyfin item with mpv and reports progress through the outbox.
@MainActor @Observable
final class PlaybackModel {
    let mpv = MPVController()
    private(set) var session: PlaybackSession
    private(set) var item: JellyfinItem?
    private(set) var error: String?
    private(set) var isOpening = false
    /// The episode to offer when this one ends.
    var nextItemId: String? { session.following.first }

    // Up Next
    struct UpNext: Equatable {
        var itemId: String
        /// "S1 · E7 – Title" (or the name).
        var title: String
        var series: String?
        var imageTag: String?
    }
    /// The next episode, once known (from `session.following`, or the series' episode list).
    private(set) var upNext: UpNext?
    /// Seconds left before the next episode plays; nil while the card isn't showing.
    private(set) var upNextCountdown: Double?
    /// No next episode (last one, or a movie): similar series, offered at the end.
    private(set) var suggestions: [JellyfinItem] = []
    private(set) var showsEndCard = false
    @ObservationIgnored private var upNextCancelled = false
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var hasNoNext = false
    @ObservationIgnored private var askedForSuggestions = false
    static let upNextSeconds: Double = 10
    #if DEBUG
    private static var openedDebugVideo = false
    #endif

    // Subtitles
    enum SubtitleState: Equatable {
        case loading, ready, none, failed(String)
    }
    private(set) var subtitles: SubtitleTrack? {
        // Split the lines into words for word marks while the episode plays.
        didSet { if let subtitles { environment.common.wordMarks.prepare(subtitles.cues.map(\.sentence)) } }
    }
    private(set) var subtitleState = SubtitleState.loading
    /// mpv's English track, drawn by mpv at the top (nil until first shown).
    private(set) var showsEnglish = false
    var hasEnglish: Bool { englishStream != nil || localEnglish != nil }

    // Lookup
    let lines: LineLookup
    var popup: LookupPopupModel? {
        get { lines.popup }
        set { lines.popup = newValue }
    }
    /// The looked-up characters in the overlay: (cue id, character range in its sentence).
    var highlight: (cue: Int, range: Range<Int>)? {
        guard let key = lines.highlight?.key, key.hasPrefix("cue-"), let id = Int(key.dropFirst(4)),
              let range = lines.highlight?.range else { return nil }
        return (id, range)
    }
    /// The magnifier: dictionary search over the paused video (cards get the paused line's media).
    var showsSearch = false
    /// The Find Subtitles sheet (Jimaku).
    var showsSubtitleSearch = false
    /// The Subtitles sheet: track, timing, Jimaku and saving to Jellyfin.
    var showsSubtitlesSheet = false
    /// The Japanese lines come from a file found on Jimaku (not Jellyfin); the timing control shows.
    private(set) var usesLocalSubtitle = false
    /// The user's timing fix for that file, in seconds (positive = later).
    private(set) var subtitleOffset: Double = 0
    /// Whether this version of the file is on Jellyfin (it only goes when the user saves it).
    private(set) var subtitleServerState = LocalSubtitle.ServerState.notSaved
    /// The file was retimed by Auto-Sync (Reset goes back to the download).
    private(set) var isSubtitleSynced = false
    /// What Auto-Sync is doing or found.
    private(set) var syncStatus: SyncStatus?
    enum SyncStatus: Equatable {
        case working
        case done(String)
        case failed(String)
    }
    /// While syncing to the audio: how far through it is ("4:30").
    private(set) var syncProgress: String?
    /// The video's own text subtitle tracks, best to sync to first.
    @ObservationIgnored private var syncReferences: [JellyfinMediaStream] = []
    /// The Japanese audio track: Jellyfin's index (for the audio-only stream) and FFmpeg's
    /// (for a downloaded file).
    @ObservationIgnored private var syncAudio: (jellyfin: Int, ffmpeg: Int?)?
    @ObservationIgnored private var unshiftedSubtitles: SubtitleTrack?
    /// Picked or retimed this time: the transcript for Lines is saved when the episode closes.
    @ObservationIgnored private var localSubtitleChanged = false
    /// Subtitles from Kaku (its transcript of the Japanese audio) when Jimaku has none.
    enum KakuSubtitles: Equatable {
        case asking
        case waiting(KakuJellyfinJob)
        case unavailable(String)
        case failed(String)
    }
    private(set) var kakuSubtitles: KakuSubtitles?
    @ObservationIgnored private var kakuTask: Task<Void, Never>?
    /// Intro, credits etc. from Jellyfin (saved for offline).
    private(set) var segments: [JellyfinMediaSegment] = []
    /// The segment playing now (the skip button shows for it).
    private(set) var currentSegment: JellyfinMediaSegment?
    /// A brief note after skipping on its own ("Skipped Intro").
    private(set) var skipNote: String?
    /// A brief message top left after a keyboard shortcut ("Speed 1.10×"), like mpv's.
    private(set) var osd: String?
    @ObservationIgnored private var osdTask: Task<Void, Never>?
    /// The cheat sheet over the video (`?`).
    var showsShortcuts = false
    /// Stream details over the video (`I`), refreshed while they show.
    private(set) var streamInfo: [(label: String, value: String)]?
    @ObservationIgnored private var infoTask: Task<Void, Never>?
    /// The Japanese lines can be hidden (`V`); lookups still work from the Lines tab.
    private(set) var showsJapanese = true
    #if DEBUG
    /// The last key presses the player saw (characters/key/modifiers in hex), for UI tests.
    var debugKeys: [String] = []
    #endif
    /// Closes the player (set by the view: full screen on iPhone/iPad, the main window on Mac).
    @ObservationIgnored var closeAction: (() -> Void)?
    @ObservationIgnored private var autoSkipped: Set<Double> = []
    @ObservationIgnored private var noteTask: Task<Void, Never>?
    /// Pictures for the scrub preview (set once the video is known).
    private(set) var thumbnails: ScrubThumbnails?

    @ObservationIgnored private let environment: PlayerEnvironment
    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var mediaSourceId: String?
    @ObservationIgnored private var playSessionId: String?
    @ObservationIgnored private var lastSaved = Date.distantPast
    /// The play session as Jellyfin last heard of it: started (not stopped yet), when and where.
    @ObservationIgnored private var sessionStarted = false
    @ObservationIgnored private var lastReported = Date.distantPast
    /// The item's streams, to report which audio and subtitle tracks are playing.
    @ObservationIgnored private var mediaStreams: [JellyfinMediaStream] = []
    /// The Jellyfin subtitle stream shown (nil for a Jimaku file or none).
    @ObservationIgnored private var subtitleStreamIndex: Int?
    /// The app went to the background with the video open (its session was ended then).
    @ObservationIgnored private var wasInBackground = false
    /// A lookup paused playback: closing the popup plays again.
    @ObservationIgnored private var resumesAfterLookup = false
    /// The app is in the background (audio only, video off).
    @ObservationIgnored private var inBackground = false
    /// AirPods, Lock Screen and Control Center controls while open.
    @ObservationIgnored private let nowPlaying = NowPlaying()
    /// mpv's time at the last change, to spot seeks.
    @ObservationIgnored private var lastTime: Double?
    /// Seconds watched and not yet written to the Stats log (written every 10 s and on close).
    @ObservationIgnored private var unloggedSeconds: Double = 0
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var choseAudio = false
    @ObservationIgnored private var englishStream: JellyfinMediaStream?
    @ObservationIgnored private var englishTrackId: Int?
    /// The downloaded file being played, if any (also used for card media).
    @ObservationIgnored private var localFile: URL?
    @ObservationIgnored private var localEnglish: URL?
    /// How often progress is saved and queued for Jellyfin, playing or paused. Jellyfin ends a
    /// session it hasn't heard from in a few minutes, and Playback Reporting only looks at a
    /// report 20 s after the last one it used, so a pause has to be repeated to be counted.
    static let saveInterval: TimeInterval = 10

    init(session: PlaybackSession, environment: PlayerEnvironment) {
        self.session = session
        self.environment = environment
        lines = LineLookup(service: environment.common.lookup)
    }

    var title: String { session.title }

    /// The title as two lines, Infuse style: "S1 · E6 – The Long Night" over the show's name.
    /// Movies (and unknown items) have only the main line.
    var titleLines: (detail: String?, main: String) {
        guard let item, item.isEpisode, let show = item.seriesName else { return (nil, item?.name ?? title) }
        let number = [item.parentIndexNumber.map { "S\($0)" }, item.indexNumber.map { "E\($0)" }].compactMap(\.self)
            .joined(separator: " · ")
        return (number.isEmpty ? item.name : "\(number) – \(item.name)", show)
    }

    func open() async {
        resetUpNext()
        #if DEBUG
        // UI tests: a local video file instead of a Jellyfin item (gesture tests without a server).
        if session.itemId.hasPrefix("/") {
            // UITEST_PLAYER_FOLLOWING=<path>: a "next episode" for the Up Next card. It and
            // UITEST_PLAYER_START apply to the first video only (the next one starts afresh).
            let firstOpen = !Self.openedDebugVideo
            Self.openedDebugVideo = true
            if firstOpen, let next = ProcessInfo.processInfo.environment["UITEST_PLAYER_FOLLOWING"], session.following.isEmpty {
                session.following = [next]
            }
            if let next = session.following.first { upNext = UpNext(itemId: next, title: "Next Test Video") }
            hasNoNext = session.following.isEmpty
            item = JellyfinItem(id: session.itemId, name: session.title, type: "Movie")
            mediaSourceId = "local"
            subtitleState = .none
            thumbnails = ScrubThumbnails(source: .video(location: session.itemId, headers: [:]))
            segments = Self.testSegments()
            // UITEST_PLAYER_START=<seconds>: open part-way in, like a resume point.
            NowPlaying.prepareAudioSession()
            mpv.load(session.itemId, start: firstOpen ? ProcessInfo.processInfo.environment["UITEST_PLAYER_START"].flatMap(Double.init) ?? 0 : 0)
            mpv.setPaused(false)
            startNowPlaying()
            return
        }
        #endif
        let client = environment.jellyfinClient()
        self.client = client
        let downloaded = environment.downloader.localFile(itemId: session.itemId)
        let saved = environment.downloader.metadata(itemId: session.itemId)
        guard client != nil || downloaded != nil else {
            error = "Sign in to Jellyfin in Settings."
            return
        }
        isOpening = true
        defer { isOpening = false }
        var item: JellyfinItem
        var source: JellyfinMediaSource?
        do {
            guard let client else { throw ConnectionError.message("Not signed in.") }
            item = try await client.item(id: session.itemId)
            let info = try await client.playbackInfo(itemId: session.itemId)
            source = info.mediaSources.first ?? item.mediaSources?.first
            playSessionId = info.playSessionId
        } catch {
            // Offline: a downloaded episode plays from its saved details.
            guard downloaded != nil, let saved else {
                self.error = error.localizedDescription
                return
            }
            item = saved.item
            playSessionId = nil
        }
        guard let sourceId = source?.id ?? saved?.mediaSourceId else {
            error = "Jellyfin has no playable file for this item."
            return
        }
        self.item = item
        mediaSourceId = sourceId
        localFile = downloaded
        thumbnails?.close()
        if let client, let info = item.trickplay(mediaSourceId: sourceId) {
            thumbnails = ScrubThumbnails(source: .trickplay(client, itemId: item.id, mediaSourceId: sourceId, info: info))
        } else if let downloaded {
            thumbnails = ScrubThumbnails(source: .video(location: downloaded.path(percentEncoded: false), headers: [:]))
        } else if let client {
            thumbnails = ScrubThumbnails(source: .video(location: client.streamURL(itemId: item.id, mediaSourceId: sourceId).absoluteString,
                                                        headers: client.playbackHeaders))
        }
        choseAudio = false
        let local = try? environment.watchProgress.progress(itemId: item.id)
        // "Play from here" (Lines) wins over the resume point; the start report says where it is.
        let start = session.startAt ?? LocalWatchProgress.resumePosition(
            local: local, server: item.resumePosition, serverDate: item.userData?.lastPlayedDate)
        NowPlaying.prepareAudioSession()
        if let downloaded {
            mpv.load(downloaded.path(percentEncoded: false), start: start)
        } else if let client {
            mpv.load(client.streamURL(itemId: item.id, mediaSourceId: sourceId, playSessionId: playSessionId),
                     headers: client.playbackHeaders, start: start)
        }
        session.startAt = nil
        mpv.setPaused(false)
        lastSaved = Date()
        lastTime = nil
        report(.started, position: start)
        startHeartbeat()
        startNowPlaying()
        if let client {
            let http = environment.common.http
            nowPlaying.loadArtwork(client.imageRequest(itemId: item.id, maxWidth: 600)) { try await http.send($0).data }
        }
        if session.title.isEmpty { session.title = PlaybackSession(item: item).title }
        let streams = source?.mediaStreams ?? item.mediaStreams ?? []
        mediaStreams = streams
        subtitleStreamIndex = nil
        englishStream = JellyfinSubtitlePicker.english(in: streams)
        syncReferences = JellyfinSubtitlePicker.syncReferences(in: streams)
        syncAudio = (streams.first { $0.isAudio && $0.isJapanese } ?? streams.first(where: \.isAudio)).map { audio in
            (audio.index, audio.ffmpegIndex(in: streams))
        }
        syncStatus = nil
        localEnglish = environment.downloader.englishSubtitles(itemId: item.id)
        englishTrackId = nil
        showsEnglish = false
        segments = []
        currentSegment = nil
        autoSkipped = []
        let segmentsTask = Task { [environment, itemId = item.id] in await environment.segments.refresh(itemId: itemId, client: client) }
        stopKaku()
        if loadLocalSubtitle(itemId: item.id) {
            // A file the user picked on Jimaku (or Kaku's) wins over Jellyfin's.
        } else if let client, source != nil {
            let japanese = JellyfinSubtitlePicker.japanese(in: streams)
            await loadSubtitles(japanese, client: client, item: item, sourceId: sourceId,
                                audioIndex: streams.first { $0.isAudio && $0.isJapanese }?.ffmpegIndex(in: streams))
            // None on Jellyfin: Kaku may have transcribed it (asked for with the rest of a season).
            if japanese == nil { followKaku(itemId: item.id, applies: false) }
        } else {
            loadSavedSubtitles(itemId: item.id)
        }
        segments = await segmentsTask.value
        updateSegment()
        await resolveUpNext(client: client, item: item)
    }

    // MARK: Up Next

    private func resetUpNext() {
        stopCountdown()
        upNext = nil
        suggestions = []
        showsEndCard = false
        upNextCancelled = false
        hasNoNext = false
        askedForSuggestions = false
    }

    /// Finds the next episode: the list the player was opened with, else the series' episodes
    /// (opened from Continue Watching, Lines or Downloads).
    private func resolveUpNext(client: JellyfinClient?, item: JellyfinItem) async {
        if session.following.isEmpty, item.isEpisode, let seriesId = item.seriesId, let client,
           let episodes = try? await client.episodes(seriesId: seriesId, seasonId: nil) {
            let after = JellyfinUpNext.episodes(after: item.id, in: episodes)
            session.following = after.map(\.id)
            upNext = after.first.map(UpNext.init)
        } else if let nextId = session.following.first {
            let next = try? await client?.item(id: nextId)
            upNext = next.map(UpNext.init) ?? UpNext(itemId: nextId, title: "Next episode")
        }
        hasNoNext = session.following.isEmpty
        updateUpNext()
    }

    /// Shows or hides the card as playback nears the end (call on time, pause and end changes).
    func updateUpNext() {
        guard item != nil, mpv.hasStarted else { return }
        let credits = segments.first { $0.kind == .outro }?.start
        let offer = JellyfinUpNext.offerTime(duration: mpv.duration, creditsStart: credits)
        let inWindow = mpv.reachedEnd || (offer.map { mpv.timePosition >= $0 } ?? false)
        if upNext != nil, !upNextCancelled, inWindow {
            if upNextCountdown == nil { startCountdown() }
        } else if upNextCountdown != nil {
            // Seeked back before the end, or cancelled.
            stopCountdown()
        }
        if hasNoNext, inWindow, !askedForSuggestions {
            askedForSuggestions = true
            Task { await loadSuggestions() }
        }
        let endCard = hasNoNext && mpv.reachedEnd
        if endCard != showsEndCard { showsEndCard = endCard }
    }

    private func startCountdown() {
        upNextCountdown = Self.upNextSeconds
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, let left = self.upNextCountdown else { return }
                // Paused holds the countdown (at the very end mpv stays paused on the last frame).
                if self.mpv.isPaused && !self.mpv.reachedEnd { continue }
                if left <= 0.25 {
                    // Not from this task: stopping the countdown cancels it, and the next
                    // episode's requests would be cancelled with it.
                    self.countdownTask = nil
                    self.upNextCountdown = nil
                    Task { await self.playNext() }
                    return
                }
                self.upNextCountdown = left - 0.25
            }
        }
    }

    private func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        upNextCountdown = nil
    }

    /// The card's Cancel: no next episode for this one.
    func cancelUpNext() {
        upNextCancelled = true
        stopCountdown()
    }

    func playUpNext() async {
        stopCountdown()
        await playNext()
    }

    /// Similar series from Jellyfin, the same library first, never a hidden one.
    private func loadSuggestions() async {
        guard let item, let client else { return }
        let target = item.seriesId ?? item.id
        guard let similar = try? await client.similar(itemId: target, limit: 12) else { return }
        var libraries: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for candidate in similar {
                group.addTask { (candidate.id, try? await client.libraryId(of: candidate.id)) }
            }
            for await (id, library) in group { libraries[id] = library }
        }
        let current = try? await client.libraryId(of: target)
        suggestions = JellyfinUpNext.suggestions(similar, libraries: libraries, currentLibrary: current ?? nil,
                                                 hidden: environment.hiddenLibraries)
    }

    /// Call when mpv's time moves: saves and reports every `saveInterval` seconds, and right
    /// away after a seek.
    func timeChanged() {
        updateSegment()
        guard mpv.hasStarted else { return }
        updateUpNext()
        let time = mpv.timePosition
        let jumped = lastTime.map { abs(time - $0) > 2 } ?? false
        // Stats: time that played forward, not seeks or pauses.
        if let lastTime, !jumped, !mpv.isPaused, time > lastTime {
            unloggedSeconds += time - lastTime
            if unloggedSeconds >= 10 { logWatching() }
        }
        // The system moves the Now Playing position along itself; it needs telling after jumps.
        if jumped || lastTime == nil { updateNowPlaying() }
        lastTime = time
        guard item != nil, jumped || Date().timeIntervalSince(lastSaved) >= Self.saveInterval else { return }
        saveProgress(.progress)
    }

    /// Writes the seconds watched so far to the Stats log, under the show (or the movie).
    private func logWatching() {
        defer { unloggedSeconds = 0 }
        guard let item, unloggedSeconds > 0 else { return }
        let subject = ActivitySubject(kind: .watching, seriesKey: item.seriesId ?? item.id, seriesTitle: item.seriesName ?? item.name,
                                      itemKey: item.id)
        try? environment.common.activity.record(subject, seconds: unloggedSeconds)
    }

    /// Call when playback pauses or resumes: saved and reported right away.
    func pauseChanged(_ paused: Bool) {
        // Played again by hand while a lookup is open: closing it shouldn't do anything then.
        if !paused { resumesAfterLookup = false }
        ScreenAwake.set(!paused)
        updateNowPlaying()
        guard item != nil, sessionStarted else { return }
        // Paused from AirPods or the Lock Screen while away: iOS will suspend the app soon, so
        // the session ends (after the pause report).
        saveProgress(paused ? .paused : .unpaused)
        if paused, inBackground { endSessionInBackground() }
    }

    /// Keeps reporting while paused (time doesn't move then, so `timeChanged` doesn't).
    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.saveInterval))
                guard let self, !Task.isCancelled else { return }
                if self.item != nil, Date().timeIntervalSince(self.lastSaved) >= Self.saveInterval {
                    self.saveProgress(.progress)
                }
            }
        }
    }

    /// mpv defaults to the file's default audio, often English: switch to Japanese once.
    func tracksChanged() {
        noteEnglishTrack()
        guard !choseAudio else { return }
        let audio = mpv.tracks.filter { $0.type == "audio" }
        guard !audio.isEmpty else { return }
        choseAudio = true
        let isJapanese = { (track: MPVController.Track) in ["jpn", "ja", "jp"].contains(track.language?.lowercased() ?? "") }
        if let selected = audio.first(where: \.isSelected), isJapanese(selected) { return }
        if let japanese = audio.first(where: isJapanese) { mpv.selectAudio(japanese.id) }
    }

    func playNext() async {
        guard let next = session.following.first else { return }
        logWatching()
        saveProgress(.stopped)
        finishLocalSubtitle()
        subtitleServerState = .notSaved
        syncStatus = nil
        session = PlaybackSession(itemId: next, title: "", following: Array(session.following.dropFirst()))
        item = nil
        error = nil
        subtitles = nil
        subtitleState = .loading
        lines.close()
        await open()
    }

    // MARK: Subtitles

    private func loadSubtitles(_ stream: JellyfinMediaStream?, client: JellyfinClient, item: JellyfinItem, sourceId: String,
                               audioIndex: Int?) async {
        guard let stream else {
            subtitleState = .none
            return
        }
        subtitleState = .loading
        do {
            let text = try await client.subtitleText(itemId: item.id, mediaSourceId: sourceId, index: stream.index)
            let track = SubtitleTrack(srt: text)
            subtitles = track
            unshiftedSubtitles = track
            subtitleOffset = 0
            subtitleState = track.cues.isEmpty ? .none : .ready
            subtitleStreamIndex = track.cues.isEmpty ? nil : stream.index
            // Kept for the Lines tab (searchable, readable offline).
            if !track.cues.isEmpty {
                try? environment.transcripts.save(
                    TranscriptInfo.make(item: item, mediaSourceId: sourceId, streamIndex: stream.index, audioIndex: audioIndex),
                    lines: TranscriptLines.mergingBuildUps(track.cues.map { ($0.start, $0.end, $0.text) }))
            }
        } catch {
            // Offline: fall back to a saved copy.
            loadSavedSubtitles(itemId: item.id, failure: error.localizedDescription)
        }
    }

    /// The transcript saved when this was played, opened in Lines or downloaded.
    private func loadSavedSubtitles(itemId: String, failure: String? = nil) {
        if let lines = try? environment.transcripts.lines(itemId: itemId), !lines.isEmpty {
            subtitles = SubtitleTrack(cues: lines.map { SubtitleCue(id: $0.cue, start: $0.start, end: $0.end, text: $0.text) })
            unshiftedSubtitles = subtitles
            subtitleOffset = 0
            subtitleState = .ready
        } else {
            subtitleState = failure.map(SubtitleState.failed) ?? .none
        }
    }

    // MARK: Subtitles from Jimaku

    /// Uses a file picked on Jimaku now, in place of any picked before. It's kept for this
    /// item; it only goes to Jellyfin if the user saves it there.
    func useSubtitle(_ picked: PickedSubtitle, source: String = "jimaku") {
        guard let item else { return }
        if source != "kaku" { stopKaku() }
        try? environment.localSubtitles.save(LocalSubtitle(
            itemId: item.id, source: source, fileName: picked.fileName, format: picked.format.rawValue, data: picked.data,
            savedAt: Date()))
        unshiftedSubtitles = picked.track
        subtitleOffset = 0
        usesLocalSubtitle = true
        isSubtitleSynced = false
        syncStatus = nil
        localSubtitleChanged = true
        subtitles = picked.track
        subtitleState = .ready
        lines.close()
        saveTranscript(picked.track)
        refreshSubtitleServerState()
    }

    // MARK: Subtitles from Kaku

    /// Whether Kaku is set up (Settings ▸ Servers), for the sheet's Transcribe buttons.
    var canUseKaku: Bool { environment.kakuClient() != nil }

    /// Asks Kaku to transcribe this episode (and the rest of its season), then uses its
    /// subtitles once they're ready, like a file picked on Jimaku.
    func transcribeWithKaku(restOfSeason: Bool) async {
        guard let item, let kaku = environment.kakuClient() else { return }
        var ids = [item.id]
        if restOfSeason, let client, let seriesId = item.seriesId,
           let episodes = try? await client.episodes(seriesId: seriesId, seasonId: item.seasonId) {
            ids += JellyfinUpNext.episodes(after: item.id, in: episodes)
                .filter { $0.parentIndexNumber == item.parentIndexNumber }.map(\.id).prefix(99)
        }
        kakuSubtitles = .asking
        do {
            let jobs = try await kaku.requestJellyfin(ids)
            guard self.item?.id == item.id, let job = jobs.first else { return }
            if job.state == .unavailable {
                kakuSubtitles = .unavailable(job.error ?? "Kaku can't transcribe this episode.")
                return
            }
            followKaku(itemId: item.id, applies: true)
        } catch {
            kakuSubtitles = .failed(error.localizedDescription)
        }
    }

    /// Checks Kaku for this episode's subtitles: uses them when ready, follows the queue while
    /// waiting. `applies` false (opening an episode) only uses them when nothing else is.
    private func followKaku(itemId: String, applies: Bool) {
        kakuTask?.cancel()
        guard let kaku = environment.kakuClient() else { return }
        kakuTask = Task { [weak self] in
            while !Task.isCancelled {
                let answer: KakuSubtitlesAnswer
                do {
                    answer = try await kaku.jellyfinSubtitles(itemId: itemId)
                } catch {
                    if applies { self?.kakuSubtitles = .failed(error.localizedDescription) }
                    return
                }
                guard let self, self.item?.id == itemId else { return }
                switch answer {
                case .ready(let text):
                    self.kakuSubtitles = nil
                    let current = self.localSubtitle
                    // A file picked meanwhile (or a Jellyfin track on screen) wins.
                    guard current == nil || current?.source == "kaku",
                          applies || (current == nil && self.subtitles == nil),
                          let picked = try? SubtitleSearchModel.read(name: "Kaku.srt", data: Data(text.utf8)) else { return }
                    self.useSubtitle(picked, source: "kaku")
                    return
                case .pending(let job):
                    if job.state == .failed {
                        self.kakuSubtitles = .failed(job.error ?? "Kaku couldn't transcribe this episode.")
                        return
                    }
                    self.kakuSubtitles = .waiting(job)
                case .missing:
                    if applies { self.kakuSubtitles = .failed("Kaku lost this episode's job. Try again.") }
                    return
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func stopKaku() {
        kakuTask?.cancel()
        kakuTask = nil
        kakuSubtitles = nil
    }

    /// Moves the lines `delta` seconds later (earlier when negative); nil resets. The device's
    /// file keeps its timing; a Jellyfin track is copied to the device first.
    func shiftSubtitles(by delta: Double?) {
        guard let base = unshiftedSubtitles, let item else { return }
        subtitleOffset = delta.map { ((subtitleOffset + $0) * 10).rounded() / 10 } ?? 0
        subtitles = base.offset(by: subtitleOffset)
        guard usesLocalSubtitle else {
            if delta != nil, subtitleStreamIndex != nil {
                Task {
                    guard await copyServerSubtitle() else { return }
                    try? environment.localSubtitles.setOffset(subtitleOffset, itemId: item.id)
                    refreshSubtitleServerState()
                }
            }
            return
        }
        try? environment.localSubtitles.setOffset(subtitleOffset, itemId: item.id)
        localSubtitleChanged = true
        refreshSubtitleServerState()
    }

    /// Makes the Jellyfin track on screen a copy on the device (as ASS when it is one, so its
    /// styling goes back up with it), with the current timing; from then on it's retimed and
    /// saved like a Jimaku file, and saving replaces the server's file when it's a separate one.
    func copyServerSubtitle() async -> Bool {
        if usesLocalSubtitle { return true }
        guard let item, let client, let mediaSourceId, let index = subtitleStreamIndex,
              let stream = mediaStreams.first(where: { $0.index == index }) else { return false }
        var format = ["ass", "ssa"].contains(stream.codec?.lowercased() ?? "") ? SubtitleFile.Format.ass : .srt
        var text = try? await client.subtitleText(itemId: item.id, mediaSourceId: mediaSourceId, index: index, format: format.rawValue)
        if text == nil, format != .srt {
            format = .srt
            text = try? await client.subtitleText(itemId: item.id, mediaSourceId: mediaSourceId, index: index)
        }
        guard let text, !usesLocalSubtitle else { return usesLocalSubtitle }
        let offset = subtitleOffset
        try? environment.localSubtitles.save(LocalSubtitle(
            itemId: item.id, source: "jellyfin", fileName: stream.displayTitle ?? stream.title ?? "Japanese", format: format.rawValue,
            data: Data(text.utf8), offset: offset, savedAt: Date(), serverIndex: index,
            serverPath: stream.isExternal == true ? stream.path : nil))
        _ = loadLocalSubtitle(itemId: item.id)
        localSubtitleChanged = true
        return true
    }

    /// The device's copy of this episode's Japanese subtitles (a retimed Jellyfin track or a Jimaku file).
    var localSubtitle: LocalSubtitle? {
        _ = subtitleServerState
        return item.flatMap { try? environment.localSubtitles.subtitle(itemId: $0.id) }
    }

    /// The server's Japanese text tracks, for the Subtitles sheet.
    var japaneseServerTracks: [JellyfinMediaStream] { JellyfinSubtitlePicker.japaneseTracks(in: mediaStreams) }

    /// The Jellyfin track on screen (nil while the device's copy is used).
    var serverTrackIndex: Int? { usesLocalSubtitle ? nil : subtitleStreamIndex }

    /// Switches to the device's copy, or to one of the server's tracks.
    func chooseSubtitles(serverIndex: Int?) async {
        guard let item else { return }
        if serverIndex == nil {
            _ = loadLocalSubtitle(itemId: item.id)
            return
        }
        guard let stream = mediaStreams.first(where: { $0.index == serverIndex }), let client, let mediaSourceId else { return }
        finishLocalSubtitle()
        usesLocalSubtitle = false
        lines.close()
        await loadSubtitles(stream, client: client, item: item, sourceId: mediaSourceId,
                            audioIndex: mediaStreams.first { $0.isAudio && $0.isJapanese }?.ffmpegIndex(in: mediaStreams))
    }

    /// Why the last save to Jellyfin failed (e.g. no subtitle permission), shown in the sheet.
    private(set) var subtitleSaveError: String?

    /// Back to the file as downloaded, with no timing fix (undoes Auto-Sync too).
    func resetSubtitleTiming() {
        guard usesLocalSubtitle else { return shiftSubtitles(by: nil) }
        guard let item else { return }
        if isSubtitleSynced {
            try? environment.localSubtitles.restoreOriginal(itemId: item.id)
            _ = loadLocalSubtitle(itemId: item.id)
        } else {
            subtitleOffset = 0
            subtitles = unshiftedSubtitles
            try? environment.localSubtitles.setOffset(0, itemId: item.id)
        }
        localSubtitleChanged = true
        syncStatus = nil
        refreshSubtitleServerState()
    }

    /// Lines the file up with the video automatically (alass's method, on the device): to
    /// one of the video's own subtitle tracks, else to the speech in its audio. The file is
    /// rewritten with the new timing; Reset goes back to the download.
    func autoSyncSubtitles() async {
        if !usesLocalSubtitle, syncStatus != .working { guard await copyServerSubtitle() else { return } }
        guard usesLocalSubtitle, syncStatus != .working, let item,
              let saved = try? environment.localSubtitles.subtitle(itemId: item.id),
              let format = SubtitleFile.Format(rawValue: saved.format),
              let original = SubtitleFile.decode(saved.originalData ?? saved.data) else { return }
        syncStatus = .working
        defer { syncProgress = nil }
        let spans = SubtitleSync.spans(SubtitleFile.track(original, format: format))
        var lastError: String?
        for reference in syncReferenceSources() {
            let referenceSpans: [SubtitleSync.Span]
            do {
                referenceSpans = try await reference.load()
            } catch {
                lastError = error.localizedDescription
                continue
            }
            let result = await Task.detached(priority: .userInitiated) { SubtitleSync.align(spans, to: referenceSpans) }.value
            guard self.item?.id == item.id else { return }
            guard let result, result.match >= Self.syncMinimumMatch else { continue }
            let text = SubtitleFile.retimed(original, format: format) { result.shift(at: $0) }
            do {
                try environment.localSubtitles.saveSynced(Data(text.utf8), itemId: item.id)
            } catch {
                syncStatus = .failed("Couldn't save the synced subtitles: \(error.localizedDescription)")
                return
            }
            let track = SubtitleFile.track(text, format: format)
            unshiftedSubtitles = track
            subtitleOffset = 0
            subtitles = track
            isSubtitleSynced = true
            localSubtitleChanged = true
            refreshSubtitleServerState()
            syncStatus = .done("Synced to \(reference.name): \(Self.describe(result))")
            return
        }
        syncStatus = .failed(lastError.map { "Couldn't sync: \($0)" } ?? "Couldn't find a good match to sync to. The timing is unchanged.")
    }

    /// Below this share of matched speech a sync is more likely wrong than right.
    static let syncMinimumMatch = 0.4

    /// "moved 1.1 s earlier", or "2 parts (−2.7 s, +51.9 s)".
    static func describe(_ result: SubtitleSync.Result) -> String {
        let shifts = result.parts.map(\.shift)
        if shifts.count == 1 {
            let shift = shifts[0]
            if abs(shift) < 0.05 { return "the timing was already right" }
            return String(format: "moved %.1f s %@", abs(shift), shift > 0 ? "later" : "earlier")
        }
        let list = shifts.map { ($0 >= 0 ? "+" : "−") + String(format: "%.1f s", abs($0)) }.joined(separator: ", ")
        return "\(shifts.count) parts (\(list))"
    }

    struct SyncReference {
        var name: String
        var load: () async throws -> [SubtitleSync.Span]
    }

    /// What Auto-Sync can line up with, best first.
    private func syncReferenceSources() -> [SyncReference] {
        var sources: [SyncReference] = []
        #if DEBUG
        // UI tests: the picked lines themselves, 2 s later.
        if ProcessInfo.processInfo.environment["UITEST_SYNC_REFERENCE"] != nil, let track = unshiftedSubtitles {
            sources.append(SyncReference(name: "the test reference") {
                SubtitleSync.spans(track).map { SubtitleSync.Span(start: $0.start + 2, end: $0.end + 2) }
            })
        }
        #endif
        if let localEnglish {
            sources.append(SyncReference(name: "the English subtitles") {
                let data = try Data(contentsOf: localEnglish)
                return Self.spans(data: data, fileName: localEnglish.lastPathComponent)
            })
        }
        if let client, let item, let mediaSourceId {
            for stream in syncReferences.prefix(3) {
                let language = stream.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
                sources.append(SyncReference(name: language.map { "the \($0) subtitles" } ?? "the video's subtitles") {
                    let text = try await client.subtitleText(itemId: item.id, mediaSourceId: mediaSourceId, index: stream.index)
                    return SubtitleSync.spans(SubtitleTrack(srt: text))
                })
            }
        }
        // The speech in the audio: from the download, else a small audio-only stream.
        let progress = reportSyncProgress
        if let localFile {
            let path = localFile.path(percentEncoded: false), track = syncAudio?.ffmpeg
            sources.append(SyncReference(name: "the audio") {
                try await MediaClipper.speech(from: path, audioTrack: track, progress: progress)
            })
        } else if let client, let item, let mediaSourceId {
            let url = client.audioOnlyStreamURL(itemId: item.id, mediaSourceId: mediaSourceId, audioIndex: syncAudio?.jellyfin)
            let headers = client.playbackHeaders
            sources.append(SyncReference(name: "the audio") {
                try await MediaClipper.speech(from: url.absoluteString, headers: headers, progress: progress)
            })
        }
        return sources
    }

    private nonisolated var reportSyncProgress: @Sendable (Double) -> Void {
        { [weak self] seconds in
            Task { @MainActor in
                guard let self, self.syncStatus == .working else { return }
                self.syncProgress = PlaybackView.format(seconds)
            }
        }
    }

    private static func spans(data: Data, fileName: String) -> [SubtitleSync.Span] {
        guard let text = SubtitleFile.decode(data), let format = SubtitleFile.format(fileName: fileName, text: text) else { return [] }
        return SubtitleSync.spans(SubtitleFile.track(text, format: format))
    }

    /// Queues the file, with the current timing, for Jellyfin (next to the episode). Asked for
    /// by the user only, after confirming.
    func saveSubtitleToJellyfin() {
        guard let item, let saved = try? environment.localSubtitles.subtitle(itemId: item.id),
              let format = SubtitleFile.Format(rawValue: saved.format) else { return }
        // Untouched files go up as they came (styling and all); retimed ones shifted in place.
        var data = saved.data
        if saved.offset != 0, let text = SubtitleFile.decode(saved.data) {
            data = Data(SubtitleFile.shifted(text, format: format, by: saved.offset).utf8)
        }
        do {
            let file = try environment.common.outboxMedia.store(data, fileExtension: format.rawValue)
            try environment.common.outbox.enqueue(
                JellyfinSubtitlePayload(itemId: item.id, format: format.rawValue, replacesPath: saved.isServerCopy ? saved.serverPath : nil),
                kind: .jellyfinSubtitle,
                media: [OutboxMediaInput(field: JellyfinSubtitleHandler.mediaField, filename: file)])
            try environment.localSubtitles.markQueued(itemId: item.id, at: Date())
            environment.common.syncNow()
        } catch {
            self.error = "Couldn't queue the subtitles for Jellyfin: \(error.localizedDescription)"
        }
        refreshSubtitleServerState()
    }

    func refreshSubtitleServerState() {
        guard let item, let saved = try? environment.localSubtitles.subtitle(itemId: item.id) else {
            subtitleServerState = .notSaved
            subtitleSaveError = nil
            return
        }
        subtitleServerState = saved.serverState
        let failed = ((try? environment.common.outbox.jobs(states: [.failed])) ?? []).first {
            $0.kind == .jellyfinSubtitle && (try? $0.decodePayload(JellyfinSubtitlePayload.self))?.itemId == item.id
        }
        subtitleSaveError = saved.serverState == .saved ? nil : failed?.lastError
    }

    /// The saved Jimaku file for the item, if there is one.
    private func loadLocalSubtitle(itemId: String) -> Bool {
        guard let saved = try? environment.localSubtitles.subtitle(itemId: itemId),
              let text = SubtitleFile.decode(saved.data), let format = SubtitleFile.Format(rawValue: saved.format) else {
            usesLocalSubtitle = false
            return false
        }
        let track = SubtitleFile.track(text, format: format)
        unshiftedSubtitles = track
        subtitleOffset = saved.offset
        subtitleServerState = saved.serverState
        isSubtitleSynced = saved.originalData != nil
        usesLocalSubtitle = true
        localSubtitleChanged = false
        subtitles = track.offset(by: saved.offset)
        subtitleState = track.cues.isEmpty ? .none : .ready
        return true
    }

    /// Saves the retimed lines for Lines, once per change.
    private func finishLocalSubtitle() {
        guard localSubtitleChanged, let subtitles else { return }
        localSubtitleChanged = false
        saveTranscript(subtitles)
    }

    private func saveTranscript(_ track: SubtitleTrack) {
        guard let item, let mediaSourceId else { return }
        try? environment.transcripts.save(
            TranscriptInfo.make(item: item, mediaSourceId: mediaSourceId, streamIndex: -1,
                                audioIndex: mpv.tracks.first { $0.type == "audio" && $0.isSelected }?.ffIndex),
            lines: TranscriptLines.mergingBuildUps(track.cues.map { ($0.start, $0.end, $0.text) }))
    }

    /// The Japanese lines on screen now.
    var currentCues: [SubtitleCue] {
        subtitles?.cues(at: mpv.timePosition) ?? []
    }

    func previousLine() {
        guard let cue = subtitles?.previous(before: mpv.timePosition) else { return }
        mpv.seek(to: cue.start)
    }

    func nextLine() {
        guard let cue = subtitles?.next(after: mpv.timePosition) else { return }
        mpv.seek(to: cue.start)
    }

    /// Goes back to the line before the one on screen and plays (AirPods triple press).
    func playLineBefore() {
        guard let cue = subtitles?.lineBefore(mpv.timePosition) else { return }
        mpv.seek(to: cue.start)
        mpv.setPaused(false)
    }

    /// Plays the current (or last) line again from its start.
    func replayLine() {
        guard let cue = subtitles?.currentOrPrevious(at: mpv.timePosition) else { return }
        mpv.seek(to: cue.start)
        mpv.setPaused(false)
    }

    func toggleEnglish() {
        if showsEnglish {
            mpv.selectSubtitle(nil)
            showsEnglish = false
            return
        }
        if let englishTrackId {
            mpv.selectSubtitle(englishTrackId)
        } else if let localEnglish {
            mpv.showSubtitles(from: localEnglish)
        } else if let englishStream, let client, let item, let mediaSourceId {
            mpv.showSubtitles(from: client.subtitleURL(itemId: item.id, mediaSourceId: mediaSourceId, index: englishStream.index))
        }
        showsEnglish = true
    }

    /// Remembers mpv's id for the English file once it's been added.
    private func noteEnglishTrack() {
        guard englishTrackId == nil, showsEnglish else { return }
        englishTrackId = mpv.tracks.first { $0.type == "sub" && $0.isExternal }?.id
    }

    // MARK: Lookup and mining

    /// Pauses and looks up the word at `characterIndex` of `cue`'s sentence. If it was
    /// playing, closing the popup plays again.
    func lookUp(_ cue: SubtitleCue, characterIndex: Int) {
        if !mpv.isPaused { resumesAfterLookup = true }
        mpv.setPaused(true)
        lines.lookUp(cue.text, characterIndex: characterIndex, key: "cue-\(cue.id)", context: miningContext(for: cue))
    }

    // MARK: Keyboard shortcuts

    /// Runs a keyboard shortcut; the keys and menu come from `PlayerShortcut`.
    func perform(_ shortcut: PlayerShortcut) {
        switch shortcut {
        case .playPause: mpv.togglePause()
        case .back5: mpv.seek(by: -5)
        case .forward5: mpv.seek(by: 5)
        case .back1: mpv.seek(by: -1)
        case .forward1: mpv.seek(by: 1)
        case .previousLine: previousLine()
        case .nextLine: nextLine()
        case .replayLine: replayLine()
        case .lineBefore: playLineBefore()
        case .lookUpLine:
            if let cue = subtitles?.currentOrPrevious(at: mpv.timePosition) { lookUp(cue, characterIndex: 0) }
        case .search:
            mpv.setPaused(true)
            showsSearch = true
        case .slower: setSpeed(mpv.speed / 1.1)
        case .faster: setSpeed(mpv.speed * 1.1)
        case .halfSpeed: setSpeed(mpv.speed / 2)
        case .doubleSpeed: setSpeed(mpv.speed * 2)
        case .normalSpeed: setSpeed(1)
        case .frameBack: mpv.frameStep(forward: false)
        case .frameForward: mpv.frameStep(forward: true)
        case .loop: cycleLoop()
        case .volumeDown, .volumeUp:
            mpv.setVolume(mpv.volume + (shortcut == .volumeUp ? 2 : -2))
            showOSD("Volume \(Int(mpv.volume.rounded()))%" + (mpv.isMuted ? " (muted)" : ""))
        case .mute:
            mpv.setMuted(!mpv.isMuted)
            showOSD(mpv.isMuted ? "Muted" : "Sound on")
        case .nextAudio: nextAudioTrack()
        case .toggleJapanese:
            showsJapanese.toggle()
            showOSD(showsJapanese ? "Japanese subtitles shown" : "Japanese subtitles hidden")
        case .nextSubtitles: Task { await nextJapaneseSubtitles() }
        case .subtitlesEarlier, .subtitlesLater:
            guard unshiftedSubtitles != nil else { return showOSD("No Japanese subtitles") }
            shiftSubtitles(by: shortcut == .subtitlesLater ? 0.1 : -0.1)
            showOSD(String(format: "Subtitle timing %+.1f s", subtitleOffset))
        case .english:
            guard hasEnglish || showsEnglish else { return showOSD("No English subtitles") }
            toggleEnglish()
            showOSD(showsEnglish ? "English subtitles on" : "English subtitles off")
        case .skip: skipSegment()
        case .previousEpisode: Task { await playPreviousEpisode() }
        case .nextEpisode:
            guard nextItemId != nil else { return showOSD("No next episode") }
            Task { await playNext() }
        case .info: toggleStreamInfo()
        case .fullScreen: PlayerWindow.toggleFullScreen()
        case .shortcuts: showsShortcuts.toggle()
        case .close: closeAction?()
        }
    }

    private func setSpeed(_ value: Double) {
        mpv.setSpeed(value)
        showOSD(String(format: "Speed %.2f×", mpv.speed))
    }

    /// mpv's A–B loop: the first press marks the start, the second the end, the third clears it.
    private func cycleLoop() {
        let now = mpv.timePosition
        switch mpv.loop {
        case (nil, _):
            mpv.setLoop(start: now, end: nil)
            showOSD("Loop start \(PlaybackView.format(now))")
        case (let start?, nil) where now > start:
            mpv.setLoop(start: start, end: now)
            showOSD("Looping \(PlaybackView.format(start))–\(PlaybackView.format(now))")
        default:
            mpv.setLoop(start: nil, end: nil)
            showOSD("Loop off")
        }
    }

    private func nextAudioTrack() {
        let audio = mpv.tracks.filter { $0.type == "audio" }
        guard audio.count > 1 else { return showOSD(audio.isEmpty ? "No audio" : "Only one audio track") }
        let current = audio.firstIndex(where: \.isSelected) ?? -1
        let next = audio[(current + 1) % audio.count]
        mpv.selectAudio(next.id)
        showOSD("Audio \((current + 1) % audio.count + 1)/\(audio.count): " + Self.describe(language: next.language, title: next.title))
    }

    /// Cycles through Jellyfin's Japanese text tracks, with the Jimaku file first if there is one.
    private func nextJapaneseSubtitles() async {
        guard let item else { return }
        let streams = JellyfinSubtitlePicker.japaneseTracks(in: mediaStreams)
        let hasLocal = (try? environment.localSubtitles.subtitle(itemId: item.id)) != nil
        let count = streams.count + (hasLocal ? 1 : 0)
        guard count > 1 else { return showOSD(count == 0 ? "No Japanese subtitles" : "Only one Japanese subtitle track") }
        // Where we are in the list: the Jimaku file is position 0 when there is one.
        let current = usesLocalSubtitle ? 0 : (streams.firstIndex { $0.index == subtitleStreamIndex } ?? -1) + (hasLocal ? 1 : 0)
        let next = (current + 1) % count
        if hasLocal && next == 0 {
            _ = loadLocalSubtitle(itemId: item.id)
            let retimed = (try? environment.localSubtitles.subtitle(itemId: item.id))?.isServerCopy == true
            showOSD("Japanese subtitles 1/\(count): " + (retimed ? "your retimed copy" : "the file from Jimaku"))
            return
        }
        let stream = streams[next - (hasLocal ? 1 : 0)]
        guard let client, let mediaSourceId else { return showOSD("Can\u{2019}t switch subtitles offline") }
        finishLocalSubtitle()
        usesLocalSubtitle = false
        lines.close()
        await loadSubtitles(stream, client: client, item: item, sourceId: mediaSourceId,
                            audioIndex: mediaStreams.first { $0.isAudio && $0.isJapanese }?.ffmpegIndex(in: mediaStreams))
        showOSD("Japanese subtitles \(next + 1)/\(count): " + Self.describe(language: nil, title: stream.title ?? stream.codec?.uppercased()))
    }

    /// The previous episode in the series' order (`<`).
    private func playPreviousEpisode() async {
        guard let item, item.isEpisode, let seriesId = item.seriesId, let client,
              let episodes = try? await client.episodes(seriesId: seriesId, seasonId: nil),
              let previous = JellyfinUpNext.episode(before: item.id, in: episodes) else {
            return showOSD("No previous episode")
        }
        session.following = JellyfinUpNext.episodes(after: previous.id, in: episodes).map(\.id)
        session.following.insert(previous.id, at: 0)
        await playNext()
    }

    private func toggleStreamInfo() {
        infoTask?.cancel()
        if streamInfo != nil {
            streamInfo = nil
            return
        }
        infoTask = Task { [weak self] in
            // Refreshed each second for a few seconds, like mpv's stats.
            for _ in 0..<8 {
                guard let self, !Task.isCancelled else { return }
                self.streamInfo = self.readStreamInfo()
                try? await Task.sleep(for: .seconds(1))
            }
            if !Task.isCancelled { self?.streamInfo = nil }
        }
    }

    private func readStreamInfo() -> [(label: String, value: String)] {
        func number(_ name: String, digits: Int = 0) -> String? {
            mpv.property(name).flatMap(Double.init).map { String(format: "%.\(digits)f", $0) }
        }
        var rows: [(String, String)] = []
        let size = [mpv.property("video-params/w"), mpv.property("video-params/h")].compactMap { $0 }.joined(separator: "×")
        let video = [mpv.property("video-codec"), size.isEmpty ? nil : size, number("container-fps", digits: 3).map { "\($0) fps" }]
            .compactMap { $0 }.joined(separator: " · ")
        if !video.isEmpty { rows.append(("Video", video)) }
        if let decoder = mpv.property("hwdec-current"), decoder != "no" { rows.append(("Decoding", "hardware (\(decoder))")) }
        else { rows.append(("Decoding", "software")) }
        let audio = [mpv.property("audio-codec-name"), number("audio-params/samplerate").map { "\($0) Hz" },
                     mpv.property("audio-params/channel-count").map { "\($0) ch" }].compactMap { $0 }.joined(separator: " · ")
        if !audio.isEmpty { rows.append(("Audio", audio)) }
        rows.append(("Dropped frames", "\(mpv.property("frame-drop-count") ?? "0") (decoder \(mpv.property("decoder-frame-drop-count") ?? "0"))"))
        if let cache = number("demuxer-cache-duration", digits: 1) { rows.append(("Buffered", "\(cache) s")) }
        rows.append(("Speed", String(format: "%.2f×", mpv.speed)))
        return rows
    }

    /// "Japanese · Commentary" from a track's language code and title.
    static func describe(language: String?, title: String?) -> String {
        let name = language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        let text = [name, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return text.isEmpty ? "Untitled" : text
    }

    func showOSD(_ text: String) {
        osd = text
        osdTask?.cancel()
        osdTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { self?.osd = nil }
        }
    }

    // MARK: Segments

    private func updateSegment() {
        // While loading, the time reads 0 before jumping to the resume point: not in the intro.
        guard mpv.hasStarted else { return }
        let segment = JellyfinMediaSegment.at(mpv.timePosition, in: segments)
        if segment != currentSegment { currentSegment = segment }
        guard let segment, segment.skipsAutomatically, !autoSkipped.contains(segment.start),
              PlayerSettings.load(environment.common.database).autoSkipsIntros else { return }
        autoSkipped.insert(segment.start)
        skipSegment()
        showNote("Skipped \(segment.kind == .recap ? "Recap" : "Intro")")
    }

    /// The skip button: past the segment, or on to the next episode during the credits.
    func skipSegment() {
        guard let segment = currentSegment ?? JellyfinMediaSegment.at(mpv.timePosition, in: segments) else { return }
        if segment.kind == .outro, nextItemId != nil {
            Task { await playNext() }
            return
        }
        // Never seek past the end (that would stop instead of showing the last moment).
        let end = mpv.duration > 0 ? min(segment.end, mpv.duration - 0.5) : segment.end
        mpv.seek(to: end)
        currentSegment = nil
    }

    var skipTitle: String? {
        guard let segment = currentSegment else { return nil }
        return segment.kind == .outro && nextItemId != nil ? "Next Episode" : segment.skipTitle
    }

    private func showNote(_ text: String, seconds: Double = 2) {
        skipNote = text
        noteTask?.cancel()
        noteTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { skipNote = nil }
        }
    }

    #if DEBUG
    /// UI tests: `UITEST_PLAYER_SEGMENTS="Intro:0:20,Outro:50:60"` for the local test video.
    private static func testSegments() -> [JellyfinMediaSegment] {
        (ProcessInfo.processInfo.environment["UITEST_PLAYER_SEGMENTS"] ?? "").split(separator: ",").compactMap { part in
            let fields = part.split(separator: ":")
            guard fields.count == 3, let kind = JellyfinMediaSegment.Kind(rawValue: String(fields[0])),
                  let start = Double(fields[1]), let end = Double(fields[2]) else { return nil }
            return JellyfinMediaSegment(kind: kind, start: start, end: end)
        }
    }
    #endif

    func popupClosed() {
        lines.close()
        if resumesAfterLookup {
            resumesAfterLookup = false
            mpv.setPaused(false)
        }
    }

    /// Card media for `cue` (or, from the magnifier, the line at the paused moment).
    func miningContext(for cue: SubtitleCue? = nil) -> VideoMiningContext? {
        guard let item, let mediaSourceId else { return nil }
        let time = mpv.timePosition
        let cue = cue ?? subtitles?.currentOrPrevious(at: time)
        // Without a line, a few seconds around the paused moment.
        let start = cue?.start ?? max(time - 3, 0)
        let end = cue?.end ?? time + 1
        return VideoMiningContext(
            client: client, localFile: localFile, item: item, mediaSourceId: mediaSourceId, start: start, end: end, at: time,
            audioTrack: mpv.tracks.first { $0.type == "audio" && $0.isSelected }?.ffIndex,
            animated: environment.animatedCardPictures)
    }

    func close() {
        logWatching()
        stopKaku()
        stopCountdown()
        nowPlaying.stop()
        ScreenAwake.set(false)
        heartbeat?.cancel()
        if item != nil { saveProgress(.stopped) }
        finishLocalSubtitle()
        thumbnails?.close()
        mpv.shutdown()
        NotificationCenter.default.post(name: .playbackDidClose, object: nil)
    }

    private func saveProgress(_ event: JellyfinProgressPayload.Event) {
        guard let item else { return }
        lastSaved = Date()
        let duration = mpv.duration > 0 ? mpv.duration : item.duration ?? 0
        let position = mpv.reachedEnd ? duration : mpv.timePosition
        try? environment.watchProgress.save(LocalWatchProgress(
            itemId: item.id, seriesId: item.seriesId, position: position, duration: duration, updatedAt: Date()))
        report(event, position: position)
    }

    /// Jellyfin's index of the audio stream mpv is playing.
    private var audioStreamIndex: Int? {
        guard let ffIndex = mpv.tracks.first(where: { $0.type == "audio" && $0.isSelected })?.ffIndex else { return nil }
        return mediaStreams.first { $0.isAudio && $0.ffmpegIndex(in: mediaStreams) == ffIndex }?.index
    }

    // MARK: Background

    /// The app left the screen (playback stops; there's no background audio): end the
    /// session now rather than leave Jellyfin a silent one, and send nothing while asleep.
    /// The app left the screen. Playing: the audio goes on (video off), as does the Jellyfin
    /// session, controlled from AirPods and the Lock Screen. Paused: the session ends (iOS
    /// suspends a silent app, which would leave Jellyfin a silent session); the controls stay,
    /// and play from them starts a new one.
    func movedToBackground() {
        guard item != nil else { return }
        inBackground = true
        mpv.setVideoEnabled(false)
        NowPlayingLog.write("background, \(mpv.isPaused ? "paused" : "playing")\(NowPlaying.sessionNote)")
        if mpv.isPaused { endSessionInBackground() }
    }

    /// Quitting (Mac): end the session; the stop is queued if it can't be sent first.
    func willTerminate() {
        guard item != nil, sessionStarted else { return }
        nowPlaying.stop()
        heartbeat?.cancel()
        saveProgress(.stopped)
    }

    private func endSessionInBackground() {
        guard sessionStarted else { return }
        heartbeat?.cancel()
        saveProgress(.stopped)
        wasInBackground = true
    }

    /// Play from AirPods or the Lock Screen: after a pause in the background the session had
    /// ended, so it starts again (with the "watched further elsewhere" check).
    private func remotePlay() async {
        if wasInBackground { await returnedFromBackground(staysInBackground: true) }
        mpv.setPaused(false)
    }

    /// Back on screen: if this episode was watched further elsewhere meanwhile, move there
    /// (still paused) instead of reporting the old spot; then start a new session.
    func returnedFromBackground(staysInBackground: Bool = false) async {
        if !staysInBackground {
            inBackground = false
            mpv.setVideoEnabled(true)
        }
        guard wasInBackground, let item else { return }
        wasInBackground = false
        if let client, let fresh = try? await client.item(id: item.id), let played = fresh.userData?.lastPlayedDate,
           played > lastReported, let position = fresh.resumePosition, abs(position - mpv.timePosition) > 2 {
            mpv.setPaused(true)
            mpv.seek(to: position)
            lastTime = position
            showNote("Moved to \(Self.clock(position)), where you left off on another device", seconds: 5)
        }
        lastSaved = Date()
        report(.started, position: mpv.timePosition)
        startHeartbeat()
        updateNowPlaying()
    }

    // MARK: Now Playing

    private func startNowPlaying() {
        nowPlaying.start(.init(
            play: { [weak self] in Task { await self?.remotePlay() } },
            pause: { [weak self] in self?.mpv.setPaused(true) },
            toggle: { [weak self] in
                guard let self else { return }
                if self.mpv.isPaused { Task { await self.remotePlay() } } else { self.mpv.setPaused(true) }
            },
            nextLine: { [weak self] in self?.nextLine() },
            lineBefore: { [weak self] in self?.playLineBefore() },
            seek: { [weak self] position in self?.mpv.seek(to: position) }))
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard item != nil else { return }
        let lines = titleLines
        nowPlaying.update(title: lines.detail ?? lines.main, series: lines.detail == nil ? nil : lines.main,
                          duration: mpv.duration > 0 ? mpv.duration : item?.duration ?? 0,
                          position: mpv.timePosition, isPaused: mpv.isPaused)
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    private func report(_ event: JellyfinProgressPayload.Event, position: Double) {
        guard let item, let mediaSourceId else { return }
        let now = Date()
        let report = JellyfinProgressPayload(
            itemId: item.id, mediaSourceId: mediaSourceId, playSessionId: playSessionId,
            positionTicks: JellyfinTicks.ticks(position), isPaused: mpv.isPaused, event: event,
            audioStreamIndex: audioStreamIndex, subtitleStreamIndex: subtitleStreamIndex, reportedAt: now)
        sessionStarted = event != .stopped
        lastReported = now
        do {
            try environment.common.outbox.enqueue(report, kind: .jellyfinProgress, coalesceKey: report.coalesceKey)
            environment.common.syncNow()
        } catch {
            self.error = "Couldn't save progress: \(error.localizedDescription)"
        }
    }
}

extension PlaybackSession {
    init(itemId: String, title: String, following: [String] = [], startAt: Double? = nil) {
        self.itemId = itemId
        self.title = title
        self.following = following
        self.startAt = startAt
    }
}

extension PlaybackModel.UpNext {
    init(_ item: JellyfinItem) {
        let number = [item.parentIndexNumber.map { "S\($0)" }, item.indexNumber.map { "E\($0)" }].compactMap(\.self)
            .joined(separator: " · ")
        self.init(itemId: item.id, title: number.isEmpty ? item.name : "\(number) – \(item.name)",
                  series: item.seriesName, imageTag: item.imageTags?["Primary"])
    }
}
