import AudiobookshelfKit
import Core
import CryptoKit
import Foundation

/// What's being listened to, for Audiobookshelf's listening sessions.
public struct ListenedItem: Equatable, Sendable {
    public var itemId: String
    /// Empty for a book.
    public var episodeId: String
    /// The episode's or book's title; nil lets the server use the item's.
    public var title: String?
    public var duration: Double

    public init(itemId: String, episodeId: String, title: String? = nil, duration: Double) {
        self.itemId = itemId
        self.episodeId = episodeId
        self.title = title
        self.duration = duration
    }

    var isBook: Bool { episodeId.isEmpty }
    var mediaType: String { isBook ? "book" : "podcast" }
}

/// Reports listening to Audiobookshelf as sessions, through the outbox (`AudiobookshelfSessionPayload`).
/// A session is one stretch of one episode or book: a pause longer than `ActivityLog.gap` (as
/// the Stats tab counts it) or another item starts the next. Each session's running totals are
/// queued about once a minute while playing and whenever `send()` is called (pause, close).
@MainActor
public final class ListeningSessionReporter {
    static let sendEvery: TimeInterval = 60

    private let outbox: OutboxStore
    private let device: AudiobookshelfDeviceInfo
    private let syncNow: () -> Void
    private let now: () -> Date
    private var current: AudiobookshelfSessionPayload?
    private var lastSent: Date?
    private var unsent = false

    public init(outbox: OutboxStore, device: AudiobookshelfDeviceInfo, syncNow: @escaping () -> Void, now: @escaping () -> Date = Date.init,
                defaults: UserDefaults = .standard) {
        ListeningSessionBackfill.noteReportingStarted(now(), defaults: defaults)
        self.outbox = outbox
        self.device = device
        self.syncNow = syncNow
        self.now = now
    }

    /// `seconds` of real playback (not seeks, at any speed) of `item`, now at `position`.
    public func listened(_ seconds: Double, item: ListenedItem, position: Double) {
        guard seconds > 0, !item.itemId.isEmpty else { return }
        let date = now()
        if let session = current, session.libraryItemId == item.itemId, (session.episodeId ?? "") == item.episodeId,
           date.timeIntervalSince(session.lastUpdate) <= ActivityLog.gap {
            current?.add(seconds, at: position, on: date)
        } else {
            send()
            let started = date.addingTimeInterval(-seconds)
            current = AudiobookshelfSessionPayload(
                id: UUID().uuidString.lowercased(), libraryItemId: item.itemId, episodeId: item.episodeId,
                mediaType: item.mediaType, displayTitle: item.title, duration: item.duration, deviceInfo: device,
                startTime: max(position - seconds, 0), currentTime: position, timeListening: seconds,
                startedAt: started, updatedAt: date)
            lastSent = nil
        }
        unsent = true
        if let lastSent, date.timeIntervalSince(lastSent) < Self.sendEvery { return }
        send()
    }

    /// Queues the session's latest totals, if they changed.
    public func send() {
        guard unsent, let current else { return }
        try? outbox.enqueue(current, kind: .audiobookshelfSession, coalesceKey: current.coalesceKey)
        unsent = false
        lastSent = now()
        syncNow()
    }
}

extension AudiobookshelfDeviceInfo {
    /// This install: the id stays the same until the app is deleted.
    public static func current(clientName: String, defaults: UserDefaults = .standard) -> AudiobookshelfDeviceInfo {
        let key = "audiobookshelf.deviceId"
        let id = defaults.string(forKey: key) ?? {
            let id = UUID().uuidString.lowercased()
            defaults.set(id, forKey: key)
            return id
        }()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return AudiobookshelfDeviceInfo(deviceId: id, clientName: clientName, clientVersion: version, model: deviceModel())
    }

    /// "iPhone16,2", "Mac15,3".
    static func deviceModel() -> String {
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let name = String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty ? "Mac" : name
        #else
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #endif
    }
}

/// Listening from before sessions were reported: one session per Stats listening row (which
/// knows the item, when and how long, but not where in it or the episode's title: the handler
/// looks that up). Each gets an id made from the device and the row, so sending them again
/// changes nothing. They end when the row ends, no later than the progress Kiku saved then, so
/// Audiobookshelf doesn't move a place for them.
/// Only rows from before the reporter first ran: later listening was reported as it happened.
public enum ListeningSessionBackfill {
    static let doneKey = "audiobookshelf.sessionsBackfilled"
    static let sinceKey = "audiobookshelf.sessionsReportedSince"

    /// The first time this install reported listening; kept from then on.
    static func noteReportingStarted(_ date: Date, defaults: UserDefaults) {
        if defaults.object(forKey: sinceKey) == nil { defaults.set(date, forKey: sinceKey) }
    }

    /// Queues them once per install (when Audiobookshelf is set up).
    @MainActor
    public static func runOnce(activity: ActivityLog, outbox: OutboxStore, device: AudiobookshelfDeviceInfo,
                               position: (String) -> (position: Double, duration: Double)?, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey), let rows = try? activity.sessions(kind: .listening, localOnly: true) else { return }
        let since = defaults.object(forKey: sinceKey) as? Date ?? .now
        for session in sessions(rows, before: since, device: device, position: position) {
            try? outbox.enqueue(session, kind: .audiobookshelfSession, coalesceKey: session.coalesceKey)
        }
        defaults.set(true, forKey: doneKey)
    }

    /// `position` gives an item key's last saved place and length, if known; rows from `since`
    /// on are left out.
    static func sessions(_ rows: [ActivitySession], before since: Date = .distantFuture, device: AudiobookshelfDeviceInfo,
                         position: (String) -> (position: Double, duration: Double)?,
                         calendar: Calendar = .current) -> [AudiobookshelfSessionPayload] {
        rows.compactMap { row in
            guard row.kind == .listening, let rowId = row.id, row.seconds >= 1, !row.itemKey.isEmpty, row.start < since else { return nil }
            let parts = row.itemKey.split(separator: "/", maxSplits: 1).map(String.init)
            let item = ListenedItem(itemId: parts[0], episodeId: parts.count > 1 ? parts[1] : "", duration: 0)
            let place = position(row.itemKey)
            return AudiobookshelfSessionPayload(
                id: id(device: device.deviceId, row: rowId), libraryItemId: item.itemId, episodeId: item.episodeId,
                mediaType: item.mediaType, duration: place?.duration ?? 0, deviceInfo: device,
                startTime: place?.position ?? 0, currentTime: place?.position ?? 0, timeListening: row.seconds,
                startedAt: row.start, updatedAt: row.end, calendar: calendar)
        }
    }

    /// A UUID made from the device and the Stats row.
    static func id(device: String, row: Int64) -> String {
        var bytes = Array(SHA256.hash(data: Data("\(device)/listening/\(row)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.joined(separator: "-")
    }
}
