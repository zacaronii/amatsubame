import AppCommon
import Foundation
import JellyfinKit
import Lookup
import PlayerKit

/// Card media for a subtitle line, cut from the stream when the card is mined:
/// the line's audio (with a little padding) and a frame from the middle of it.
struct VideoMiningContext: MiningContext {
    var streamURL: String
    var headers: [String: String]
    var start: Double
    var end: Double
    /// When the screenshot is taken (the paused frame, if it's inside the line).
    var frameTime: Double
    /// The audio stream to clip (FFmpeg index); nil for the file's default.
    var audioTrack: Int?
    /// The picture is the line as an animated GIF (Settings ▸ Watching ▸ Card Picture).
    var animated = false
    var miscInfo: String
    var seriesKey: String?
    var seriesTitle: String?

    /// Audio padding, so the first and last syllables aren't clipped.
    static let leadIn = 0.15, tail = 0.35

    /// The frame (or the animated line) and the line's audio from one open of the stream, each
    /// tried once more if it fails (a dropped connection, a decoder hiccup). An animation that
    /// fails twice falls back to a still frame.
    func cardMedia() async -> CardMedia {
        let media = await clip(animated: animated)
        guard animated, media.picture == nil else { return media }
        var still = await clip(animated: false)
        if still.picture != nil { still.problems.append("Still picture: the animated one couldn't be made.") }
        return still
    }

    private func clip(animated: Bool) async -> CardMedia {
        var picture: Data?, audio: SentenceAudio?
        var problems: [String] = []
        for attempt in 1...2 {
            let frameFile = Self.temporaryFile(animated ? "gif" : "jpg"), audioFile = Self.temporaryFile("m4a")
            defer {
                try? FileManager.default.removeItem(at: frameFile)
                try? FileManager.default.removeItem(at: audioFile)
            }
            do {
                let result = try await MediaClipper.card(
                    from: streamURL, headers: headers, frameAt: frameTime, frameTo: frameFile,
                    animate: animated ? start...max(end, start) : nil,
                    start: max(start - Self.leadIn, 0), end: end + Self.tail, audioTrack: audioTrack, audioTo: audioFile)
                if picture == nil { picture = (try? result.frame.get()).flatMap { try? Data(contentsOf: $0) } }
                if audio == nil {
                    audio = (try? result.audio.get()).flatMap { try? Data(contentsOf: $0) }
                        .map { SentenceAudio(data: $0, fileExtension: "m4a") }
                }
                problems = []
                if picture == nil, case .failure(let error) = result.frame { problems.append("No picture: \(error.localizedDescription)") }
                if audio == nil, case .failure(let error) = result.audio { problems.append("No sentence audio: \(error.localizedDescription)") }
            } catch {
                problems = ["No picture or sentence audio: \(MediaClipper.ClipError(error).localizedDescription)"]
            }
            if problems.isEmpty || attempt == 2 { break }
        }
        return CardMedia(picture: picture, pictureIsAnimated: animated && picture != nil, audio: audio, problems: problems)
    }

    func pictureData() async -> Data? {
        let file = Self.temporaryFile("jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? await MediaClipper.frame(from: streamURL, headers: headers, at: frameTime, to: file)) != nil else { return nil }
        return try? Data(contentsOf: file)
    }

    func sentenceAudio() async -> SentenceAudio? {
        let file = Self.temporaryFile("m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? await MediaClipper.audio(from: streamURL, headers: headers, start: max(start - Self.leadIn, 0),
                                             end: end + Self.tail, audioTrack: audioTrack, to: file)) != nil,
              let data = try? Data(contentsOf: file) else { return nil }
        return SentenceAudio(data: data, fileExtension: "m4a")
    }

    private static func temporaryFile(_ fileExtension: String) -> URL {
        URL.temporaryDirectory.appending(path: "clip-\(UUID().uuidString).\(fileExtension)")
    }
}

extension VideoMiningContext {
    /// Media for the line `start`–`end` of a Jellyfin item: from the downloaded file when
    /// there is one (works offline), otherwise streamed from the server. The screenshot is at
    /// `time` when that's inside the line, else the line's middle. Nil with neither.
    init?(client: JellyfinClient?, localFile: URL?, itemId: String, mediaSourceId: String, start: Double, end: Double,
          at time: Double?, audioTrack: Int?, show: String, episode: String?, seriesKey: String? = nil, animated: Bool = false) {
        let location: String
        let headers: [String: String]
        if let localFile {
            location = localFile.path(percentEncoded: false)
            headers = [:]
        } else if let client {
            location = client.streamURL(itemId: itemId, mediaSourceId: mediaSourceId).absoluteString
            headers = client.playbackHeaders
        } else {
            return nil
        }
        self.init(
            streamURL: location, headers: headers, start: start, end: end,
            frameTime: time.flatMap { (start...max(end, start)).contains($0) ? $0 : nil } ?? (start + end) / 2,
            audioTrack: audioTrack, animated: animated, miscInfo: CardSource.miscInfo(show: show, episode: episode, time: start),
            seriesKey: seriesKey ?? itemId, seriesTitle: show)
    }

    init?(client: JellyfinClient?, localFile: URL?, item: JellyfinItem, mediaSourceId: String, start: Double, end: Double,
          at time: Double?, audioTrack: Int?, animated: Bool = false) {
        self.init(client: client, localFile: localFile, itemId: item.id, mediaSourceId: mediaSourceId, start: start, end: end,
                  at: time, audioTrack: audioTrack, show: item.seriesName ?? item.name,
                  episode: item.seriesName == nil ? nil : item.episodeLabel, seriesKey: item.seriesId ?? item.id, animated: animated)
    }
}
