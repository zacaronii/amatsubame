import Core
import Foundation

// Listening sessions (Audiobookshelf's stats, history and `GET /api/me/listening-sessions`).
// The apps report them as local sessions (`POST /api/session/local-all`, as the official apps
// do for downloads): the server creates the session the first time it sees an id and afterwards
// updates its currentTime, timeListening and updatedAt, so a retried send never counts twice.
// For a new session it fills mediaMetadata, the titles and the duration from the library item.
// It moves the item's progress only when the session is newer than it. Checked against
// Audiobookshelf 2.36.1 (`PlaybackSessionManager.syncLocalSession`).

/// The device a session was listened on (Audiobookshelf's `deviceInfo`).
public struct AudiobookshelfDeviceInfo: Codable, Equatable, Sendable {
    public var deviceId: String
    public var clientName: String
    public var clientVersion: String
    public var manufacturer: String
    public var model: String

    public init(deviceId: String, clientName: String, clientVersion: String, manufacturer: String = "Apple", model: String) {
        self.deviceId = deviceId
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.manufacturer = manufacturer
        self.model = model
    }
}

/// One listening session, in Audiobookshelf's `PlaybackSession` shape; queued in the outbox
/// (coalesced per session, the newest totals win).
public struct AudiobookshelfSessionPayload: Codable, Equatable, Sendable {
    /// Made on the device (a UUID).
    public var id: String
    public var libraryItemId: String
    /// Nil for a book.
    public var episodeId: String?
    /// "podcast" or "book".
    public var mediaType: String
    /// Nil or empty: the server uses the item's.
    public var displayTitle: String?
    public var displayAuthor: String?
    public var duration: Double
    /// 3: local (Audiobookshelf's `PlayMethod.LOCAL`).
    public var playMethod: Int
    public var mediaPlayer: String
    public var deviceInfo: AudiobookshelfDeviceInfo
    /// Positions in the item, in seconds.
    public var startTime: Double
    public var currentTime: Double
    /// Seconds of real playback, the whole session's.
    public var timeListening: Double
    /// Milliseconds since 1970.
    public var startedAt: Int64
    public var updatedAt: Int64
    /// The day it started, on the device ("2026-11-18", "Wednesday"): Audiobookshelf's stats group by it.
    public var date: String
    public var dayOfWeek: String

    public init(id: String, libraryItemId: String, episodeId: String?, mediaType: String, displayTitle: String? = nil,
                displayAuthor: String? = nil, duration: Double, mediaPlayer: String = "AVPlayer", deviceInfo: AudiobookshelfDeviceInfo,
                startTime: Double, currentTime: Double, timeListening: Double, startedAt: Date, updatedAt: Date,
                calendar: Calendar = .current) {
        self.id = id
        self.libraryItemId = libraryItemId
        self.episodeId = episodeId.flatMap { $0.isEmpty ? nil : $0 }
        self.mediaType = mediaType
        self.displayTitle = displayTitle
        self.displayAuthor = displayAuthor
        self.duration = duration
        playMethod = 3
        self.mediaPlayer = mediaPlayer
        self.deviceInfo = deviceInfo
        self.startTime = startTime
        self.currentTime = currentTime
        self.timeListening = timeListening
        self.startedAt = Self.milliseconds(startedAt)
        self.updatedAt = Self.milliseconds(updatedAt)
        (date, dayOfWeek) = Self.day(of: startedAt, calendar: calendar)
    }

    public var coalesceKey: String { "abs-session:\(id)" }

    public var lastUpdate: Date { Date(timeIntervalSince1970: Double(updatedAt) / 1000) }

    /// More listening: `seconds` played, now at `position`.
    public mutating func add(_ seconds: Double, at position: Double, on date: Date) {
        timeListening += seconds
        currentTime = position
        updatedAt = Self.milliseconds(date)
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func day(of date: Date, calendar: Calendar) -> (String, String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "EEEE"
        return (day, formatter.string(from: date))
    }
}

extension AudiobookshelfClient {
    struct SessionResults: Decodable {
        struct Result: Decodable {
            var id: String?
            var success: Bool
            var error: String?
        }
        var results: [Result]
    }

    /// Sends a session (new or updated). Nil when the server took it, else its reason (the item
    /// was deleted, for one).
    public func syncSession(_ session: AudiobookshelfSessionPayload) async throws(ConnectionError) -> String? {
        struct Body: Encodable {
            var sessions: [AudiobookshelfSessionPayload]
            var deviceInfo: AudiobookshelfDeviceInfo
        }
        let request: URLRequest
        do {
            request = try .json("POST", url("api/session/local-all"), body: Body(sessions: [session], deviceInfo: session.deviceInfo))
        } catch {
            throw .message(error.localizedDescription)
        }
        let answer = try await sendDecoding(SessionResults.self, request)
        guard let result = answer.results.first else { return "No answer for the session" }
        return result.success ? nil : (result.error ?? "Not saved")
    }
}

/// Delivers queued listening sessions to Audiobookshelf.
public struct AudiobookshelfSessionHandler: OutboxHandler {
    public let kind = OutboxJobKind.audiobookshelfSession
    /// Built per send so changes in Settings take effect; nil when Audiobookshelf isn't set up.
    let makeClient: @Sendable () throws -> AudiobookshelfClient?

    public init(makeClient: @escaping @Sendable () throws -> AudiobookshelfClient?) {
        self.makeClient = makeClient
    }

    public func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws {
        var payload: AudiobookshelfSessionPayload
        do {
            payload = try job.decodePayload(AudiobookshelfSessionPayload.self)
        } catch {
            throw OutboxPermanentFailure("Unreadable listening session: \(error.localizedDescription)")
        }
        guard let client = try makeClient() else {
            throw ConnectionError.message("Audiobookshelf isn't set up.")
        }
        // The server names a new session after the show; a backfilled one doesn't know its episode's title.
        if payload.displayTitle == nil, let episodeId = payload.episodeId {
            payload.displayTitle = try? await client.item(id: payload.libraryItemId).media.episodes?.first { $0.id == episodeId }?.title
        }
        let refusal: String?
        do {
            refusal = try await client.syncSession(payload)
        } catch let error {
            if case .server(let status) = error, (400..<500).contains(status), status != 408, status != 429 {
                throw OutboxPermanentFailure("Audiobookshelf rejected the listening session (HTTP \(status)).")
            }
            throw error
        }
        if let refusal { throw OutboxPermanentFailure("Audiobookshelf didn't save the listening session: \(refusal).") }
    }
}
