import AppCommon
import Core
import JellyfinKit
import Lookup
import PlayerKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Opens an episode's subtitles in Lines, optionally at one line (from search).
struct TranscriptRoute: Hashable {
    var itemId: String
    var title: String
    var focusCue: Int?
}

/// One episode's Japanese subtitles as a feed of lines: fetched and saved the first
/// time (only the subtitle text), then read from the device.
@MainActor @Observable
final class TranscriptModel {
    enum State: Equatable {
        case loading, ready, noJapanese, failed(String)
    }

    let itemId: String
    private(set) var info: TranscriptInfo?
    private(set) var lines: [TranscriptLine] = []
    private(set) var state = State.loading
    let lookup: LineLookup
    @ObservationIgnored private let environment: PlayerEnvironment

    init(itemId: String, environment: PlayerEnvironment) {
        self.itemId = itemId
        self.environment = environment
        lookup = LineLookup(service: environment.common.lookup)
    }

    func load() async {
        let store = environment.transcripts
        if let saved = try? store.transcript(itemId: itemId), let lines = try? store.lines(itemId: itemId), !lines.isEmpty {
            info = saved
            self.lines = lines
            state = .ready
            environment.common.wordMarks.prepare(lines.map { TappableLine.sentence($0.text) })
            return
        }
        guard let client = environment.jellyfinClient() else {
            state = .failed("Connect to Jellyfin to load these subtitles.")
            return
        }
        do {
            let item = try await client.item(id: itemId)
            guard let source = item.mediaSources?.first else {
                state = .failed("Jellyfin has no file for this item.")
                return
            }
            let streams = source.mediaStreams ?? item.mediaStreams ?? []
            guard let japanese = JellyfinSubtitlePicker.japanese(in: streams) else {
                state = .noJapanese
                return
            }
            let track = SubtitleTrack(srt: try await client.subtitleText(itemId: itemId, mediaSourceId: source.id, index: japanese.index))
            guard !track.cues.isEmpty else {
                state = .noJapanese
                return
            }
            let info = TranscriptInfo.make(item: item, mediaSourceId: source.id, streamIndex: japanese.index,
                                           audioIndex: streams.first { $0.isAudio && $0.isJapanese }?.ffmpegIndex(in: streams))
            try store.save(info, lines: track.cues.map { ($0.start, $0.end, $0.text) })
            self.info = info
            lines = try store.lines(itemId: itemId)
            state = .ready
            environment.common.wordMarks.prepare(lines.map { TappableLine.sentence($0.text) })
        } catch {
            guard !error.isCancellation else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func tap(_ line: TranscriptLine, characterIndex: Int) {
        lookup.lookUp(line.text, characterIndex: characterIndex, key: String(line.cue), context: miningContext(for: line))
    }

    /// The line's audio and a screenshot when Jellyfin is reachable; just the source otherwise.
    func miningContext(for line: TranscriptLine) -> any MiningContext {
        guard let info else { return TextMiningContext(miscInfo: "") }
        let episode = info.seriesName == nil ? nil : info.episodeLabel
        // The downloaded file when there is one, else the stream; just the source when neither works.
        return VideoMiningContext(client: environment.jellyfinClient(), localFile: environment.downloader.localFile(itemId: info.itemId),
                                  itemId: info.itemId, mediaSourceId: info.mediaSourceId, start: line.start, end: line.end,
                                  at: nil, audioTrack: info.audioIndex, show: info.showName, episode: episode,
                                  seriesKey: info.seriesId ?? info.itemId, animated: environment.animatedCardPictures)
            ?? TextMiningContext(miscInfo: CardSource.miscInfo(show: info.showName, episode: episode, time: line.start))
    }
}

struct TranscriptView: View {
    @Environment(PlayerEnvironment.self) private var environment
    @Environment(CommonEnvironment.self) private var common
    let route: TranscriptRoute
    @Binding var playback: PlaybackSession?
    @State private var model: TranscriptModel?
    @State private var query = ""
    /// The line at the episode's last watched position.
    @State private var currentCue: Int?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(route.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            if model == nil {
                let model = TranscriptModel(itemId: route.itemId, environment: environment)
                self.model = model
                await model.load()
            }
        }
    }

    @ViewBuilder private func content(_ model: TranscriptModel) -> some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .noJapanese:
            ContentUnavailableView("No Japanese Subtitles", systemImage: "captions.bubble",
                                   description: Text("Jellyfin has no Japanese text subtitles for this video."))
        case .failed(let message):
            ContentUnavailableView("Couldn't Load Subtitles", systemImage: "wifi.exclamationmark", description: Text(message))
        case .ready:
            lines(model)
        }
    }

    private func lines(_ model: TranscriptModel) -> some View {
        let search = query.trimmingCharacters(in: .whitespaces)
        let shown = search.isEmpty ? model.lines : model.lines.filter { $0.text.localizedCaseInsensitiveContains(search) }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !search.isEmpty {
                        Text("\(shown.count) \(shown.count == 1 ? "line" : "lines")")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("transcript.matches")
                    } else if common.mining.marksWords {
                        WordMarkLegend()
                    }
                    ForEach(shown, id: \.cue) { line in
                        row(line, model: model)
                            .id(line.cue)
                    }
                }
                .padding()
            }
            .onAppear {
                currentCue = Self.currentCue(in: model.lines, position: watchedPosition())
                if let cue = route.focusCue ?? currentCue { proxy.scrollTo(cue, anchor: .center) }
            }
            .onChange(of: search.isEmpty) { _, cleared in
                if cleared, let cue = route.focusCue ?? currentCue { proxy.scrollTo(cue, anchor: .center) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playbackDidClose)) { _ in
                // Back from the player: follow to where watching stopped.
                currentCue = Self.currentCue(in: model.lines, position: watchedPosition())
                if let currentCue { withAnimation { proxy.scrollTo(currentCue, anchor: .center) } }
            }
        }
        .searchable(text: $query, prompt: "Search this episode")
        .navigationSubtitle(subtitle(model))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Play", systemImage: "play.fill") {
                    playback = PlaybackSession(itemId: route.itemId, title: model.info.map(Self.title) ?? route.title)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .accessibilityIdentifier("transcript.play")
            }
        }
        .sheet(item: Binding(get: { model.lookup.popup }, set: { if $0 == nil { model.lookup.close() } })) { popup in
            LookupPopupView(service: common.lookup, model: popup)
                .overlay(alignment: .topTrailing) {
                    Button { model.lookup.close() } label: {
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

    private func row(_ line: TranscriptLine, model: TranscriptModel) -> some View {
        TranscriptLineRow(line: line, highlighted: model.lookup.highlightedRange(for: String(line.cue)),
                          isEmphasized: (route.focusCue ?? currentCue) == line.cue,
                          onPlay: { play(from: line, model: model) }) { index in
            model.tap(line, characterIndex: index)
        }
        .contextMenu {
            Button("Play from Here", systemImage: "play") { play(from: line, model: model) }
            Button("Copy", systemImage: "doc.on.doc") { Self.copy(TappableLine.sentence(line.text)) }
        }
    }

    /// Opens the player a moment before `line`, so its first syllable isn't cut.
    private func play(from line: TranscriptLine, model: TranscriptModel) {
        playback = PlaybackSession(itemId: route.itemId, title: model.info.map(Self.title) ?? route.title,
                                   startAt: max(line.start - 0.3, 0))
    }

    /// "S2 · E8 · The Future · 412 lines".
    private func subtitle(_ model: TranscriptModel) -> String {
        let count = "\(model.lines.count) \(model.lines.count == 1 ? "line" : "lines")"
        guard let info = model.info else { return count }
        let episode = info.season.map { season in info.episode.map { "S\(season) · E\($0)" } ?? "S\(season)" }
        return [episode, info.seriesName == nil ? nil : info.title, count].compactMap(\.self).joined(separator: " · ")
    }

    private func watchedPosition() -> Double? {
        (try? environment.watchProgress.progress(itemId: route.itemId))?.position
    }

    /// The last line that started at or before `position` (nil before the first, or unwatched).
    static func currentCue(in lines: [TranscriptLine], position: Double?) -> Int? {
        guard let position, position > 1 else { return nil }
        return lines.last { $0.start <= position }?.cue
    }

    static func title(_ info: TranscriptInfo) -> String {
        [info.seriesName, info.episodeLabel, info.title].compactMap(\.self).joined(separator: " · ")
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// One line of a transcript: its time and tappable text.
struct TranscriptLineRow: View {
    @Environment(CommonEnvironment.self) private var common
    let line: TranscriptLine
    var highlighted: Range<Int>?
    /// The line searched for, or the one playing in the live feed.
    var isEmphasized = false
    var isDimmed = false
    /// Plays the episode from this line (its time is a button); nil in the live feed.
    var onPlay: (() -> Void)?
    let onTap: (Int) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let onPlay {
                Button(action: onPlay) {
                    Text(TranscriptView.timestamp(line.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isEmphasized ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 48, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play from \(TranscriptView.timestamp(line.start))")
                .accessibilityIdentifier("transcript.playLine")
            } else {
                Text(TranscriptView.timestamp(line.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
            }
            TappableLine(text: line.text, highlighted: highlighted, marks: common.wordMarks.marks(for: TappableLine.sentence(line.text)),
                         fontSize: 20, style: .plain, alignment: .leading, onTap: onTap)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .opacity(isDimmed ? 0.55 : 1)
        .background(isEmphasized ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 6))
    }
}
