import Foundation
import KikuWatchLink
import Observation
import Security
import WatchConnectivity

/// What's on this watch (docs/KIKU_PLAN.md milestone 2): the phone's list, downloaded straight
/// from Audiobookshelf with a background URLSession (watchOS runs it when it chooses, most
/// readily on the charger). Files live in Application Support/Audio, named by `WatchItem.fileName`;
/// one that's there is ready. The state of each goes back to the phone in this side's context.
@MainActor @Observable
final class WatchDownloads: NSObject, URLSessionDownloadDelegate {
    static let sessionIdentifier = "com.amatsubame.kiku.watch.downloads"

    /// The phone's list, as it last arrived.
    private(set) var items: [WatchItem] = []
    private(set) var statuses: [String: WatchItemStatus] = [:]
    private(set) var freeBytes: Int64?
    /// Each item's cover, by item id (Application Support/Covers): kept from the phone's state
    /// when it plays one, else fetched from Audiobookshelf (once a launch). Watch mode's artwork.
    private(set) var covers: [String: Data] = [:]
    @ObservationIgnored var onCover: (() -> Void)?
    @ObservationIgnored private let coverFolder = URL.applicationSupportDirectory.appending(path: "Covers")
    @ObservationIgnored private var coversAsked: Set<String> = []

    /// Asks the phone for a token that lasts (nil when it can't be reached).
    @ObservationIgnored var requestAccess: (() async -> WatchAccess?)?
    @ObservationIgnored private let folder = URL.applicationSupportDirectory.appending(path: "Audio")
    /// Send Now's files from the phone, by key, until they're moved into place (one can arrive
    /// before the list that names it).
    @ObservationIgnored private let incoming = URL.applicationSupportDirectory.appending(path: "Audio/Incoming")
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var access: WatchAccess?
    /// Removed here: kept off until the phone's list drops them too.
    @ObservationIgnored private var removedHere: Set<String>
    /// Tasks restarted after a 401 with a fresh token, so a refused one doesn't loop.
    @ObservationIgnored private var retried: Set<String> = []
    @ObservationIgnored private var sent: WatchInventory?
    @ObservationIgnored private var backgroundEventsDone: (() -> Void)?
    @ObservationIgnored private var lastProgress: [String: Date] = [:]

    private static let removedKey = "kiku.watch.removedHere"

    override init() {
        removedHere = Set(UserDefaults.standard.stringArray(forKey: Self.removedKey) ?? [])
        super.init()
        access = WatchKeychain.load()
        try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: coverFolder, withIntermediateDirectories: true)
        for file in (try? FileManager.default.contentsOfDirectory(at: coverFolder, includingPropertiesForKeys: nil)) ?? [] {
            covers[file.lastPathComponent] = try? Data(contentsOf: file)
        }
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // MARK: The list

    /// The phone's list arrived (or the context it came in): download what's missing, delete
    /// what's gone, keep the token.
    func apply(_ library: WatchLibrary) async {
        if library.access != access {
            access = library.access
            WatchKeychain.save(library.access)
        }
        let wanted = Set(library.items.map(\.key))
        // The phone dropped what was removed here: nothing to hold back any more.
        removedHere.formIntersection(wanted)
        saveRemoved()
        for item in items where !wanted.contains(item.key) { await delete(item) }
        // Its file changed (the phone looked it up again after a 404): tried again.
        for item in library.items where statuses[item.key]?.state == .failed
            && items.contains(where: { $0.key == item.key && $0.ino != item.ino }) {
            statuses[item.key] = nil
        }
        items = library.items.filter { !removedHere.contains($0.key) }
        await reconcile()
    }

    /// Removed on the watch: deleted now, and the phone is told (it may be out of reach).
    func remove(_ item: WatchItem) async {
        removedHere.insert(item.key)
        saveRemoved()
        await delete(item)
        items.removeAll { $0.key == item.key }
        WCSession.default.transferUserInfo(WatchMessages.userInfo(removed: item.key))
        report()
    }

    func file(for item: WatchItem) -> URL? {
        let url = folder.appending(path: item.fileName)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Statuses from what's on disk and the running tasks; starts what's missing.
    func reconcile() async {
        let tasks = await session.allTasks
        let running = Dictionary(tasks.compactMap { task in task.taskDescription.map { ($0, task) } }, uniquingKeysWith: { first, _ in first })
        var missing: [WatchItem] = []
        for item in items {
            if file(for: item) == nil, FileManager.default.fileExists(atPath: incomingFile(item.key).path(percentEncoded: false)) {
                running[item.key]?.cancel()
                place(incomingFile(item.key), for: item)
            }
            if let file = file(for: item) {
                statuses[item.key] = WatchItemStatus(state: .ready, bytesDone: Self.size(of: file))
            } else if item.fromPhone {
                // Send Now: the phone sends it; downloading it here too would only compete.
                running[item.key]?.cancel()
                statuses[item.key] = WatchItemStatus(state: .waiting, message: "Coming from your iPhone")
            } else if let task = running[item.key] {
                // From the task itself: while the app was suspended, no progress was delivered.
                statuses[item.key] = WatchItemStatus(state: task.countOfBytesReceived > 0 ? .downloading : .waiting,
                                                     bytesDone: task.countOfBytesReceived, bytesTotal: Self.expected(task, item))
            } else if statuses[item.key]?.state != .failed {
                missing.append(item)
            }
        }
        statuses = statuses.filter { key, _ in items.contains { $0.key == key } }
        if !missing.isEmpty { await start(missing) }
        report()
        fetchCovers()
    }

    // MARK: Covers

    /// The phone's cover for something it plays: kept when that item is on this watch without one.
    func keepCover(_ data: Data, for itemId: String) {
        guard covers[itemId] == nil, items.contains(where: { $0.itemId == itemId }) else { return }
        saveCover(data, for: itemId)
    }

    private func saveCover(_ data: Data, for itemId: String) {
        covers[itemId] = data
        try? data.write(to: coverFolder.appending(path: itemId))
        onCover?()
    }

    /// Covers for items without one; the ones no item needs any more go.
    private func fetchCovers() {
        let needed = Set(items.map(\.itemId))
        for itemId in covers.keys where !needed.contains(itemId) {
            covers[itemId] = nil
            try? FileManager.default.removeItem(at: coverFolder.appending(path: itemId))
        }
        let missing = needed.filter { covers[$0] == nil && !coversAsked.contains($0) }
        guard !missing.isEmpty else { return }
        coversAsked.formUnion(missing)
        Task {
            guard let access = await usableAccess() else { return }
            for itemId in missing {
                guard let (data, response) = try? await URLSession.shared.data(for: access.coverRequest(itemId: itemId)),
                      (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { continue }
                saveCover(data, for: itemId)
            }
        }
    }

    /// Send Now's file arrived (moved out of WatchConnectivity's inbox already).
    func received(file: URL, key: String) async {
        let destination = incomingFile(key)
        try? FileManager.default.removeItem(at: destination)
        guard (try? FileManager.default.moveItem(at: file, to: destination)) != nil else { return }
        await reconcile()
    }

    private func incomingFile(_ key: String) -> URL {
        incoming.appending(path: key.replacingOccurrences(of: "/", with: "-"))
    }

    /// Starts again one that failed (the row's Retry).
    func retry(_ item: WatchItem) async {
        statuses[item.key] = nil
        retried.remove(item.key)
        await reconcile()
    }

    private func start(_ missing: [WatchItem]) async {
        guard let access = await usableAccess() else {
            for item in missing {
                statuses[item.key] = WatchItemStatus(state: .waiting, message: self.access == nil
                    ? "Sign in to Audiobookshelf in Kiku on your iPhone" : "Waiting for your iPhone")
            }
            return
        }
        for item in missing {
            let task = session.downloadTask(with: access.request(for: item))
            task.taskDescription = item.key
            if let size = item.size { task.countOfBytesClientExpectsToReceive = size }
            // Small ones (an episode) first, so they aren't stuck behind a whole book.
            task.priority = (item.size ?? .max) < 50_000_000 ? URLSessionTask.highPriority : URLSessionTask.lowPriority
            task.resume()
            statuses[item.key] = WatchItemStatus(state: .waiting, bytesTotal: item.size)
        }
    }

    /// The token, or a fresh one from the phone when an access token is running out.
    private func usableAccess() async -> WatchAccess? {
        if let access, access.lasts() { return access }
        guard let fresh = await requestAccess?() else { return nil }
        access = fresh
        WatchKeychain.save(fresh)
        return fresh
    }

    private func delete(_ item: WatchItem) async {
        for task in await session.allTasks where task.taskDescription == item.key { task.cancel() }
        try? FileManager.default.removeItem(at: folder.appending(path: item.fileName))
        try? FileManager.default.removeItem(at: incomingFile(item.key))
        statuses[item.key] = nil
    }

    private func saveRemoved() {
        UserDefaults.standard.set(Array(removedHere).sorted(), forKey: Self.removedKey)
    }

    // MARK: Telling the phone

    private func report() {
        freeBytes = Self.freeSpace()
        let inventory = WatchInventory(items: statuses, freeBytes: freeBytes, updatedAt: .now)
        if let sent, sent.matches(inventory) { return }
        guard WCSession.default.activationState == .activated else { return }
        do {
            try WCSession.default.updateApplicationContext(WatchMessages.context(inventory))
            sent = inventory
        } catch {}
    }

    private static func freeSpace() -> Int64? {
        // (watchOS has no "for important usage" figure.)
        let values = try? URL.applicationSupportDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    private static func size(of file: URL) -> Int64 {
        Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    private static func expected(_ task: URLSessionTask, _ item: WatchItem) -> Int64? {
        task.countOfBytesExpectedToReceive > 0 ? task.countOfBytesExpectedToReceive : item.size
    }

    // MARK: Background events

    /// watchOS woke the app for this session's events: call `done` once they're delivered.
    func handleBackgroundEvents(_ done: @escaping () -> Void) {
        backgroundEventsDone = done
    }

    // MARK: URLSessionDownloadDelegate (on the session's queue)

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        Task { @MainActor in
            let now = Date()
            if let last = self.lastProgress[key], now.timeIntervalSince(last) < 1 { return }
            self.lastProgress[key] = now
            self.statuses[key] = WatchItemStatus(state: .downloading, bytesDone: totalBytesWritten,
                                                 bytesTotal: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
            self.report()
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        // The file must be moved before this returns.
        let moved: URL? = {
            guard (200..<300).contains(status) else { return nil }
            let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            return (try? FileManager.default.moveItem(at: location, to: temporary)) != nil ? temporary : nil
        }()
        Task { @MainActor in self.finished(key, status: status, file: moved) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, let key = task.taskDescription else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        let message = error.localizedDescription
        Task { @MainActor in
            self.lastProgress[key] = nil
            guard !cancelled, self.items.contains(where: { $0.key == key }) else { return }
            self.statuses[key] = WatchItemStatus(state: .failed, message: message)
            self.report()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundEventsDone?()
            self.backgroundEventsDone = nil
        }
    }

    private func finished(_ key: String, status: Int, file: URL?) {
        lastProgress[key] = nil
        guard let item = items.first(where: { $0.key == key }) else {
            if let file { try? FileManager.default.removeItem(at: file) }
            return
        }
        if status == 401, !retried.contains(key) {
            // The token ran out before watchOS started it: once more with a fresh one.
            retried.insert(key)
            access = access?.isAPIKey == true ? access : nil
            statuses[key] = nil
            Task { await reconcile() }
            return
        }
        guard let file else {
            statuses[key] = WatchItemStatus(state: .failed, message: status == 401 || status == 403
                ? "Audiobookshelf refused the watch's sign-in" : "Audiobookshelf answered \(status)", httpStatus: status)
            report()
            return
        }
        place(file, for: item)
        report()
    }

    /// Moves a finished file (downloaded here or sent by the phone) to where it plays from.
    private func place(_ file: URL, for item: WatchItem) {
        let destination = folder.appending(path: item.fileName)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: file, to: destination)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = destination
            try? url.setResourceValues(values)
            statuses[item.key] = WatchItemStatus(state: .ready, bytesDone: Self.size(of: destination))
        } catch {
            statuses[item.key] = WatchItemStatus(state: .failed, message: "Couldn't save it: \(error.localizedDescription)")
        }
    }
}

/// The watch's Audiobookshelf token, in the Keychain (secrets never go in defaults).
enum WatchKeychain {
    private static let service = "com.amatsubame.kiku.watch"
    private static let account = "audiobookshelf"

    static func save(_ access: WatchAccess?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard let access, let data = try? JSONEncoder().encode(access) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> WatchAccess? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(WatchAccess.self, from: data)
    }
}
