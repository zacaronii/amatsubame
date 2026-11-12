import AppCommon
import Core
import Foundation
import Lookup

/// Where an episode's audio comes from (the download, or the stream with its header) and what's
/// made from it: clips, a local copy for cutting card audio, and mining contexts. Shared by the
/// player and the Marks tab.
@MainActor
final class EpisodeAudio {
    let entry: EpisodeEntry
    private(set) var source: (url: URL, headers: [String: String])?
    private(set) var coverRequest: URLRequest?
    /// A streamed episode fetched once for cutting card clips; deleted by `discard()`.
    private var clipSource: Task<URL?, Never>?
    /// Kaku's clip of a streamed source (nil without Kaku: then the whole file is fetched).
    private var remoteClip: (@Sendable (Double, Double) async -> Data?)?

    init(entry: EpisodeEntry) {
        self.entry = entry
    }

    /// Finds the audio: the download first, else the stream. Nil (with why) when neither works.
    func resolve(environment: KikuEnvironment) async -> String? {
        if source != nil { return nil }
        if entry.fileCount > 1 { return "This book has \(entry.fileCount) files. Kiku plays single-file books for now." }
        guard let ino = entry.episode.audioFile?.ino else { return "This episode has no audio file." }
        let client = environment.audiobookshelfClient()
        if let file = environment.localAudioFile(entry.id) {
            source = (file, [:])
        } else if let client, let request = try? await client.audioRequest(itemId: entry.itemId, ino: ino), let url = request.url {
            source = (url, request.allHTTPHeaderFields ?? [:])
        }
        if let client { coverRequest = try? await client.coverRequest(itemId: entry.itemId, width: 600) }
        // Streaming: Kaku cuts card clips (a few KB) instead of the whole file being fetched.
        if let source, !source.url.isFileURL, let kaku = environment.kakuClient() {
            let (itemId, episodeId) = (entry.itemId, entry.episode.id)
            remoteClip = { start, end in try? await kaku.clip(itemId: itemId, episodeId: episodeId, start: start, end: end) }
        }
        return source == nil ? "Sign in to Audiobookshelf in Settings to play this." : nil
    }

    /// The stream asked for again, with a renewed sign-in (nil for a download, or when it can't be had).
    func renewStream(environment: KikuEnvironment) async -> (url: URL, headers: [String: String])? {
        guard let current = source, !current.url.isFileURL, let ino = entry.episode.audioFile?.ino,
              let client = environment.audiobookshelfClient(),
              let request = try? await client.audioRequest(itemId: entry.itemId, ino: ino), let url = request.url else { return nil }
        source = (url, request.allHTTPHeaderFields ?? [:])
        return source
    }

    /// The episode as a local file for cutting clips: the download, or the stream fetched once.
    func localAudio() async -> URL? {
        guard let source else { return nil }
        if source.url.isFileURL { return source.url }
        if let clipSource { return await clipSource.value }
        var request = URLRequest(url: source.url)
        for (field, value) in source.headers { request.setValue(value, forHTTPHeaderField: field) }
        let task = Task<URL?, Never> {
            guard let (temporary, response) = try? await URLSession.shared.download(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let file = URL.temporaryDirectory.appending(path: "kiku-clip-source-\(UUID().uuidString).\(source.url.pathExtension.isEmpty ? "mp3" : source.url.pathExtension)")
            do {
                try FileManager.default.moveItem(at: temporary, to: file)
                return file
            } catch {
                return nil
            }
        }
        clipSource = task
        let file = await task.value
        if file == nil { clipSource = nil }
        return file
    }

    /// Plays part of the episode (a line, or a mark's 15 seconds); a second tap stops it.
    func playClip(_ clip: ClipPlayer, from start: Double, to end: Double) {
        guard let source else { return }
        if clip.isPlaying { return clip.stop() }
        clip.play(url: source.url, headers: source.headers, from: max(start, 0), to: end)
    }

    /// Card media for a line: its audio and the artwork, or only the text without a source.
    func miningContext(for sentence: AudioSentence) -> any MiningContext {
        let miscInfo = Self.miscInfo(entry, at: sentence.start)
        guard source != nil else { return TextMiningContext(miscInfo: miscInfo) }
        return AudioMiningContext(localAudio: { [weak self] in await self?.localAudio() }, remoteClip: remoteClip, coverRequest: coverRequest,
                                  start: sentence.start, end: sentence.end, miscInfo: miscInfo, seriesKey: entry.itemId,
                                  seriesTitle: entry.isBook ? entry.episode.title : entry.showTitle)
    }

    /// "Show — Episode · 13:19", or for a book "Book — Chapter · 1:13:19".
    static func miscInfo(_ entry: EpisodeEntry, at time: Double) -> String {
        if entry.isBook {
            return CardSource.miscInfo(show: entry.episode.title, episode: entry.chapter(at: time)?.title ?? "", time: time)
        }
        return CardSource.miscInfo(show: entry.showTitle, episode: entry.episode.title, time: time)
    }

    /// Deletes the temporary copy of a stream, if one was made.
    func discard() {
        guard let clipSource else { return }
        self.clipSource = nil
        Task { if let file = await clipSource.value, file.path().contains("/kiku-clip-source-") { try? FileManager.default.removeItem(at: file) } }
    }
}

/// What the lookup sheet needs from the screen it opened on (the player, or Marks).
@MainActor
protocol LineLookupHost: AnyObject {
    /// The line looked up, for the sheet's sentence bar.
    var lookupSentence: AudioSentence? { get }
    var clip: ClipPlayer { get }
    var lookup: LineLookup { get }
    /// Looking up paused playback, which resumes when the sheet closes.
    var resumesOnClose: Bool { get }
    func playClip(_ sentence: AudioSentence)
    func popupClosed()
}
