#if os(iOS)
import AppCommon
import AudiobookshelfKit
import Core
import Foundation
import KikuWatchLink
import Observation

/// What goes on Apple Watch (docs/KIKU_PLAN.md milestone 2). The phone keeps the list (Core's
/// `KikuWatchItemStore`) and `WatchBridge` sends it whole, with a token, in its context; the
/// watch downloads straight from Audiobookshelf and answers with each item's state.
///
/// The token: an admin gets an API key of its own, "Kiku on Apple Watch", which doesn't run out
/// (watchOS starts downloads when it chooses, often hours later on the charger) and is revoked
/// when you sign out or switch accounts. Anyone else's watch gets the phone's access token (an
/// hour), and asks for a fresh one before downloading (`WatchCommand.freshAccess`).
@MainActor @Observable
final class WatchLibraryModel {
    static let apiKeyName = "Kiku on Apple Watch"
    /// The watch's API key in the Keychain: JSON of `StoredKey`.
    static let apiKeySecret = SecretKey(rawValue: "kiku.watch.apiKey")

    private(set) var items: [WatchItem] = []
    /// What the watch last said: each item's state and its free space.
    private(set) var inventory: WatchInventory?
    /// A watch is paired and has Kiku (set by `WatchBridge`): Send to Watch shows only then.
    var isWatchAppInstalled = false
    /// When listening from the watch last arrived (milestone 3).
    private(set) var lastSynced: Date?
    /// Send Now: how far each file the phone is sending has got, by key (set by `WatchBridge`).
    var sending: [String: Double] = [:]
    /// Send Now that failed, by key, with why.
    var sendErrors: [String: String] = [:]

    @ObservationIgnored private unowned let environment: KikuEnvironment
    @ObservationIgnored private let store: KikuWatchItemStore
    @ObservationIgnored private let listening: KikuWatchListeningStore
    /// The last stretch from the watch per item key: when it ended (Continue from… names the watch).
    @ObservationIgnored private(set) var watchPlayedAt: [String: Date] = [:]
    @ObservationIgnored private var access: WatchAccess?
    /// The list or the token changed: `WatchBridge` sends the context again.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Something was added: `WatchBridge` also wakes the watch for it, when it can.
    @ObservationIgnored var onAdded: (() -> Void)?
    /// Send Now: `WatchBridge` sends the phone's file, or stops sending it.
    @ObservationIgnored var onSendFile: ((WatchItem, URL) -> Void)?
    @ObservationIgnored var onCancelFile: ((String) -> Void)?
    /// Kiku's complication is on the watch's face, so the phone can wake Kiku there
    /// (`transferCurrentComplicationUserInfo`); otherwise the list waits until watchOS wakes it.
    var wakesWatch = false

    struct StoredKey: Codable, Equatable {
        var id: String
        var token: String
        var server: URL
        var userId: String
    }

    init(environment: KikuEnvironment) {
        self.environment = environment
        store = KikuWatchItemStore(database: environment.common.database)
        listening = KikuWatchListeningStore(database: environment.common.database)
        items = ((try? store.all()) ?? []).compactMap { try? JSONDecoder().decode(WatchItem.self, from: $0.item) }
        lastSynced = try? listening.lastAppliedAt()
    }

    /// What the watch should have, with the token while there's anything to download.
    var library: WatchLibrary {
        WatchLibrary(items: items, access: items.isEmpty ? nil : access,
                     places: Dictionary(uniqueKeysWithValues: items.compactMap { item in place(item.key).map { (item.key, $0) } }),
                     acknowledged: (try? listening.recent()) ?? [:])
    }

    /// The newer of this phone's place and Audiobookshelf's, as the player resumes.
    private func place(_ key: String) -> WatchPlace? {
        let local = (try? environment.listenProgress.progress(itemId: key)) ?? nil
        let server = environment.library.progress[key]
        let serverPlace = server.map { WatchPlace(position: $0.isFinished ? 0 : $0.currentTime, updatedAt: $0.updatedAt) }
        guard let local else { return serverPlace }
        if let serverPlace, serverPlace.updatedAt >= local.updatedAt { return serverPlace }
        return WatchPlace(position: local.position, updatedAt: local.updatedAt)
    }

    func contains(_ key: String) -> Bool { items.contains { $0.key == key } }

    /// The item's state on the watch, until it says: it hasn't picked the list up yet (it does
    /// when watchOS wakes Kiku there, or when you open it).
    func status(_ key: String) -> WatchItemStatus {
        inventory?.items[key] ?? WatchItemStatus(state: .waiting, message: wakesWatch
            ? "On its way to the watch"
            : "Not on the watch's list yet: opening Kiku on the watch picks it up, or add Kiku's complication to your watch face so it starts by itself")
    }

    /// A download's figure is from the watch's last report: a while ago, it may have moved on.
    func staleness(_ key: String, now: Date = .now) -> String? {
        guard let inventory, let status = inventory.items[key], status.state == .downloading || status.state == .waiting,
              now.timeIntervalSince(inventory.updatedAt) > 120 else { return nil }
        return "As of \(inventory.updatedAt.formatted(.relative(presentation: .named))): the watch reports progress while Kiku is open on it"
    }

    // MARK: Sending and removing

    /// Adds an episode or a single-file book (Kiku plays no others).
    func send(_ entry: EpisodeEntry) async {
        guard let audio = entry.episode.audioFile, entry.fileCount == 1, !contains(entry.id) else { return }
        let item = WatchItem(
            itemId: entry.itemId, episodeId: entry.episode.id, ino: audio.ino, fileExtension: audio.fileExtension,
            title: entry.episode.title, subtitle: entry.showTitle, duration: entry.duration,
            size: (entry.episode.size ?? entry.book?.media.size).map(Int64.init),
            chapters: entry.chapters.map { WatchItem.Chapter(title: $0.title, start: $0.start) }, addedAt: .now)
        guard let data = try? JSONEncoder().encode(item) else { return }
        try? store.save(key: item.key, item: data, addedAt: item.addedAt)
        items.append(item)
        await prepareAccess()
        onChange?()
        onAdded?()
    }

    /// This phone has it downloaded and the watch doesn't have it yet: Send Now can send it.
    func canSendFromPhone(_ key: String) -> Bool {
        contains(key) && sending[key] == nil && status(key).state != .ready && environment.downloader.localFile(key: key) != nil
    }

    /// Send Now: the phone's own download goes over WatchConnectivity (for a server the watch
    /// can't reach), and the watch stops downloading it itself.
    func sendFromPhone(_ key: String) {
        guard let index = items.firstIndex(where: { $0.key == key }), let file = environment.downloader.localFile(key: key) else { return }
        items[index].fromPhone = true
        if let data = try? JSONEncoder().encode(items[index]) { try? store.save(key: key, item: data, addedAt: items[index].addedAt) }
        sendErrors[key] = nil
        sending[key] = 0
        onChange?()
        onSendFile?(items[index], file)
    }

    /// Send Now didn't get there: the watch goes back to downloading it itself (Send from iPhone
    /// can be tried again).
    func sendFailed(_ key: String, _ message: String) {
        sendErrors[key] = message
        guard let index = items.firstIndex(where: { $0.key == key }), items[index].fromPhone else { return }
        items[index].fromPhone = false
        if let data = try? JSONEncoder().encode(items[index]) { try? store.save(key: key, item: data, addedAt: items[index].addedAt) }
        onChange?()
    }

    /// "Sending from iPhone: 40%", or why it couldn't.
    func sendingText(_ key: String) -> String? {
        if let fraction = sending[key] { return "Sending from iPhone: \(Int((fraction * 100).rounded(.down)))%" }
        return sendErrors[key].map { "Couldn't send from iPhone: \($0)" }
    }

    /// Takes it off the list; the watch deletes its file when the list arrives.
    func remove(_ key: String) {
        guard contains(key) else { return }
        onCancelFile?(key)
        sending[key] = nil
        sendErrors[key] = nil
        try? store.remove(key)
        items.removeAll { $0.key == key }
        inventory?.items[key] = nil
        onChange?()
    }

    func received(_ inventory: WatchInventory) {
        self.inventory = inventory
        // Downloaded by the watch after all, or the file's there: nothing left to send.
        for key in sending.keys where inventory.items[key]?.state == .ready {
            onCancelFile?(key)
            sending[key] = nil
        }
    }

    // MARK: Listening from the watch (milestone 3)

    /// Applies the watch's listening as if it had happened here: Stats, an Audiobookshelf session
    /// (the watch's id, so sending it again only updates it), and the place when it's newer than
    /// what the phone and Audiobookshelf have. Each stretch adds only what's new since the version
    /// applied before. Returns what's applied now, for the watch to drop.
    @discardableResult
    func apply(_ stretches: [WatchListening], now: Date = .now) -> [String: Date] {
        var applied: [String: Date] = [:]
        for stretch in stretches.sorted(by: { $0.endedAt < $1.endedAt }) {
            let before = (try? listening.applied(stretch.id)) ?? nil
            if let before, before.endedAt >= stretch.endedAt {
                applied[stretch.id] = before.endedAt
                continue
            }
            let added = stretch.seconds - (before?.seconds ?? 0)
            let item = items.first { $0.key == stretch.key }
            if added > 0 {
                let series = stretch.episodeId.isEmpty ? stretch.title : (item?.subtitle ?? stretch.title)
                let subject = ActivitySubject(kind: .listening, seriesKey: stretch.itemId, seriesTitle: series, itemKey: stretch.key)
                try? environment.common.activity.record(subject, at: stretch.endedAt, seconds: added)
            }
            let session = AudiobookshelfSessionPayload(
                id: stretch.id, libraryItemId: stretch.itemId, episodeId: stretch.episodeId,
                mediaType: stretch.episodeId.isEmpty ? "book" : "podcast", displayTitle: stretch.title, duration: stretch.duration,
                deviceInfo: Self.watchDevice, startTime: stretch.startPosition, currentTime: stretch.endPosition,
                timeListening: stretch.seconds, startedAt: stretch.startedAt, updatedAt: stretch.endedAt)
            try? environment.common.outbox.enqueue(session, kind: .audiobookshelfSession, coalesceKey: session.coalesceKey)
            moveProgress(for: stretch)
            try? listening.markApplied(stretch.id, seconds: stretch.seconds, endedAt: stretch.endedAt, at: now)
            watchPlayedAt[stretch.key] = max(watchPlayedAt[stretch.key] ?? .distantPast, stretch.endedAt)
            applied[stretch.id] = stretch.endedAt
        }
        if !stretches.isEmpty {
            lastSynced = now
            environment.common.syncNow(retryWaiting: false)
        }
        return applied
    }

    /// The watch's place, unless the phone or Audiobookshelf has a newer one (the latest wins;
    /// the player asks before going back a long way, `PlaybackModel.resumeChoice`).
    private func moveProgress(for stretch: WatchListening) {
        let key = stretch.key
        let local = (try? environment.listenProgress.progress(itemId: key)) ?? nil
        let server = environment.library.progress[key]
        if let local, local.updatedAt >= stretch.endedAt { return }
        if let server, server.updatedAt >= stretch.endedAt { return }
        // What's playing on the phone right now is newer still.
        if let playback = environment.playback, playback.key == key, playback.audio.isPlaying { return }
        let duration = stretch.duration > 0 ? stretch.duration : (server?.duration ?? 0)
        guard duration > 0 else { return }
        let finished = stretch.finished || (server?.isFinished == true && stretch.endPosition >= duration - 5)
        let time = finished ? duration : stretch.endPosition
        let payload = AudiobookshelfProgressPayload(itemId: stretch.itemId, episodeId: stretch.episodeId, currentTime: time,
                                                    duration: duration, isFinished: finished, reportedAt: stretch.endedAt)
        try? environment.common.outbox.enqueue(payload, kind: .audiobookshelfProgress, coalesceKey: payload.coalesceKey)
        environment.library.update(progress: AudiobookshelfProgress(
            libraryItemId: stretch.itemId, episodeId: stretch.episodeId, duration: duration, progress: time / duration,
            currentTime: time, isFinished: finished, lastUpdate: stretch.endedAt.timeIntervalSince1970 * 1000))
    }

    /// Audiobookshelf's device for the watch: its own id, made from this phone's.
    static var watchDevice: AudiobookshelfDeviceInfo {
        let phone = AudiobookshelfDeviceInfo.current(clientName: "Kiku")
        return AudiobookshelfDeviceInfo(deviceId: "\(phone.deviceId)-watch", clientName: "Kiku on Apple Watch",
                                        clientVersion: phone.clientVersion, model: "Apple Watch")
    }

    // MARK: Access

    /// A token for the watch: the API key when there is (or can be) one, else the phone's own,
    /// renewed if it's running out.
    @discardableResult
    func prepareAccess() async -> WatchAccess? {
        guard let account = try? environment.common.accounts.account(.audiobookshelf),
              let client = environment.audiobookshelfClient() else {
            await signedOut()
            return nil
        }
        if let key = storedKey(), key.server == account.baseURL, key.userId == account.userId {
            access = WatchAccess(server: key.server, token: key.token, isAPIKey: true)
            return access
        }
        // Another account than the key's: revoke that one first.
        await revokeKey()
        if let userId = account.userId, let me = try? await client.me(), me.type == "admin" || me.type == "root",
           let created = try? await client.createAPIKey(name: Self.apiKeyName, userId: userId), let token = created.apiKey {
            let key = StoredKey(id: created.id, token: token, server: account.baseURL, userId: userId)
            if let data = try? JSONEncoder().encode(key), let json = String(data: data, encoding: .utf8) {
                try? environment.common.secrets.setSecret(json, for: Self.apiKeySecret)
            }
            access = WatchAccess(server: account.baseURL, token: token, isAPIKey: true)
            return access
        }
        guard let token = try? await client.bearerToken() else { return access }
        // Signed in with an API key of your own: that one doesn't run out either.
        let phone = WatchAccess(server: account.baseURL, token: token, isAPIKey: false)
        access = WatchAccess(server: account.baseURL, token: token, isAPIKey: phone.expiry == nil)
        return access
    }

    /// What the watch asks for before it downloads: a token good for a while.
    func freshAccess() async -> WatchAccess? {
        if let access, access.lasts() { return access }
        let fresh = await prepareAccess()
        onChange?()
        return fresh
    }

    /// Signed out of Audiobookshelf: the watch forgets its token and the key is revoked.
    func signedOut() async {
        await revokeKey()
        guard access != nil else { return }
        access = nil
        onChange?()
    }

    private func storedKey() -> StoredKey? {
        guard let json = try? environment.common.secrets.secret(for: Self.apiKeySecret) else { return nil }
        return try? JSONDecoder().decode(StoredKey.self, from: Data(json.utf8))
    }

    /// Deletes the watch's API key on the server, authorized by the key itself (the phone may
    /// be signed out already), then from the Keychain.
    private func revokeKey() async {
        guard let key = storedKey() else { return }
        var request = URLRequest(url: key.server.appending(path: "api/api-keys/\(key.id)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(key.token)", forHTTPHeaderField: "Authorization")
        _ = try? await environment.common.http.sendRaw(request)
        try? environment.common.secrets.setSecret(nil, for: Self.apiKeySecret)
        if access?.token == key.token { access = nil }
    }
}
#endif
