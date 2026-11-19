#if os(iOS)
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

    @ObservationIgnored private unowned let environment: KikuEnvironment
    @ObservationIgnored private let store: KikuWatchItemStore
    @ObservationIgnored private var access: WatchAccess?
    /// The list or the token changed: `WatchBridge` sends the context again.
    @ObservationIgnored var onChange: (() -> Void)?

    struct StoredKey: Codable, Equatable {
        var id: String
        var token: String
        var server: URL
        var userId: String
    }

    init(environment: KikuEnvironment) {
        self.environment = environment
        store = KikuWatchItemStore(database: environment.common.database)
        items = ((try? store.all()) ?? []).compactMap { try? JSONDecoder().decode(WatchItem.self, from: $0.item) }
    }

    /// What the watch should have, with the token while there's anything to download.
    var library: WatchLibrary {
        WatchLibrary(items: items, access: items.isEmpty ? nil : access,
                     places: Dictionary(uniqueKeysWithValues: items.compactMap { item in place(item.key).map { (item.key, $0) } }))
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

    /// The item's state on the watch ("Waiting for your watch" until it says).
    func status(_ key: String) -> WatchItemStatus {
        inventory?.items[key] ?? WatchItemStatus(state: .waiting, message: "Waiting for your watch")
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
    }

    /// Takes it off the list; the watch deletes its file when the list arrives.
    func remove(_ key: String) {
        guard contains(key) else { return }
        try? store.remove(key)
        items.removeAll { $0.key == key }
        inventory?.items[key] = nil
        onChange?()
    }

    func received(_ inventory: WatchInventory) {
        self.inventory = inventory
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
