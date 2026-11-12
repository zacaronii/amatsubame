import Core
import Foundation
import JellyfinKit
import Observation
import PlayerKit

/// What's saved with a downloaded episode so it plays, shows subtitles and mines offline.
struct DownloadedEpisode: Codable, Equatable {
    var itemId: String
    var name: String
    var type: String
    var seriesId: String?
    var seriesName: String?
    var seasonId: String?
    var season: Int?
    var episode: Int?
    var runtime: Double?
    var mediaSourceId: String
    /// The media file's name in the downloads folder.
    var file: String
    /// The Japanese audio stream as FFmpeg numbers it (nil: the file's default).
    var audioIndex: Int?
    var englishSubtitleFile: String?
    var imageFile: String?

    init(item: JellyfinItem, source: JellyfinMediaSource) {
        let streams = source.mediaStreams ?? item.mediaStreams ?? []
        itemId = item.id
        name = item.name
        type = item.type
        seriesId = item.seriesId
        seriesName = item.seriesName
        seasonId = item.seasonId
        season = item.parentIndexNumber
        episode = item.indexNumber
        runtime = item.duration
        mediaSourceId = source.id
        file = "\(item.id).\(source.container?.split(separator: ",").first.map(String.init) ?? "mkv")"
        audioIndex = streams.first { $0.isAudio && $0.isJapanese }?.ffmpegIndex(in: streams)
    }

    /// Enough of the Jellyfin item to play it without the server.
    var item: JellyfinItem {
        var item = JellyfinItem(id: itemId, name: name, type: type)
        item.seriesId = seriesId
        item.seriesName = seriesName
        item.seasonId = seasonId
        item.parentIndexNumber = season
        item.indexNumber = episode
        item.runTimeTicks = runtime.map(JellyfinTicks.ticks)
        return item
    }
}

/// Downloads Jellyfin originals with a background URLSession, so they continue while
/// the app is in the background. Records live in `DownloadStore`; files in `directory`.
@MainActor @Observable
final class EpisodeDownloader {
    static let sessionIdentifier = "com.amatsubame.miru.downloads"

    /// Every episode download, by item id (kept current from the store).
    private(set) var records: [String: DownloadRecord] = [:]
    private(set) var lastError: String?
    let directory: URL

    @ObservationIgnored private let store: DownloadStore
    @ObservationIgnored private let transcripts: TranscriptStore
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let http: HTTPClient
    @ObservationIgnored private let makeClient: @MainActor () -> JellyfinClient?
    @ObservationIgnored private var session: URLSession!
    /// Downloads being paused on purpose, so their cancellation isn't reported as a failure.
    @ObservationIgnored private var pausing: Set<Int64> = []
    @ObservationIgnored private var lastProgressWrite: [Int64: Date] = [:]
    @ObservationIgnored private var backgroundEventsDone: (() -> Void)?

    init(directory: URL, store: DownloadStore, transcripts: TranscriptStore, database: AppDatabase, http: HTTPClient,
         background: Bool = true, makeClient: @escaping @MainActor () -> JellyfinClient?) {
        self.directory = directory
        self.store = store
        self.transcripts = transcripts
        self.database = database
        self.http = http
        self.makeClient = makeClient
        let configuration = background
            ? URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
            : URLSessionConfiguration.default
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        let delegate = DownloadSessionDelegate(directory: directory) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    // MARK: Lifecycle

    /// Keeps `records` current and reconciles with the transfers the system is still running.
    func start() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        await reconcile()
        do {
            for try await all in store.observe(kind: .jellyfinItem) {
                records = Dictionary(all.map { ($0.itemKey, $0) }, uniquingKeysWith: { $1 })
            }
        } catch {}
    }

    /// Records that say "downloading" without a live transfer (the app was killed) resume
    /// from saved resume data, or start again.
    private func reconcile() async {
        let tasks = await session.allTasks
        let live = Set(tasks.compactMap { Self.recordId(of: $0) })
        for record in (try? store.all(kind: .jellyfinItem)) ?? [] where record.isActive {
            guard let id = record.id, !live.contains(id) else { continue }
            if FileManager.default.fileExists(atPath: resumeFile(id).path(percentEncoded: false)) {
                try? store.setState(id, .paused)
            } else {
                await startTransfer(record)
            }
        }
    }

    /// iOS relaunches the app for finished background transfers; wait until they're handled.
    func handleBackgroundEvents() async {
        await withCheckedContinuation { continuation in
            backgroundEventsDone = { continuation.resume() }
        }
    }

    // MARK: Actions

    /// Downloads an episode or movie: the subtitles and poster first (small), then the file.
    func download(_ item: JellyfinItem) async {
        guard let client = makeClient() else {
            lastError = "Sign in to Jellyfin to download."
            return
        }
        if let existing = records[item.id], existing.state == .done || existing.isActive { return }
        do {
            let full = item.mediaSources == nil ? try await client.item(id: item.id) : item
            guard let source = full.mediaSources?.first else {
                lastError = "Jellyfin has no file for \(full.name)."
                return
            }
            var meta = DownloadedEpisode(item: full, source: source)
            await saveExtras(&meta, item: full, source: source, client: client)
            let record = try store.enqueue(DownloadRecord(
                kind: .jellyfinItem, itemKey: full.id, seriesKey: full.seriesId ?? full.id,
                seriesTitle: full.seriesName ?? full.name,
                title: full.seriesName == nil ? full.name : [full.episodeLabel, full.name].compactMap(\.self).joined(separator: " · "),
                // The season name only when it adds something (it's often the show's name again).
                detail: full.seriesName == nil ? full.productionYear.map(String.init)
                    : full.seasonName.flatMap { $0 == full.seriesName ? nil : $0 },
                bytesTotal: source.size, extra: try JSONEncoder().encode(meta), createdAt: Date()))
            await startTransfer(record)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func download(_ items: [JellyfinItem]) async {
        for item in items { await download(item) }
    }

    /// Stops a transfer, keeping what's been downloaded so it can resume.
    func pause(_ record: DownloadRecord) async {
        guard let id = record.id else { return }
        pausing.insert(id)
        if let task = await task(for: id) as? URLSessionDownloadTask {
            let data = await task.cancelByProducingResumeData()
            if let data { try? data.write(to: resumeFile(id)) }
        }
        try? store.setState(id, .paused)
    }

    func resume(_ record: DownloadRecord) async {
        guard let id = record.id else { return }
        try? store.setState(id, .queued)
        await startTransfer(record)
    }

    /// Removes the download and its files (the saved subtitles stay for Lines).
    func delete(_ record: DownloadRecord) async {
        guard let id = record.id else { return }
        pausing.insert(id)
        await task(for: id)?.cancel()
        let meta = Self.metadata(record)
        for name in [meta?.file ?? record.file, meta?.englishSubtitleFile, meta?.imageFile].compactMap(\.self) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
        try? FileManager.default.removeItem(at: resumeFile(id))
        try? store.remove(id)
    }

    // MARK: Lookups

    /// The downloaded file for an item, if it's complete and on the device.
    func localFile(itemId: String) -> URL? {
        guard let record = records[itemId] ?? (try? store.download(kind: .jellyfinItem, itemKey: itemId)) ?? nil,
              record.state == .done, let file = record.file else { return nil }
        let url = directory.appending(path: file)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    func metadata(itemId: String) -> DownloadedEpisode? {
        (records[itemId] ?? (try? store.download(kind: .jellyfinItem, itemKey: itemId)) ?? nil).flatMap(Self.metadata)
    }

    func englishSubtitles(itemId: String) -> URL? {
        guard let name = metadata(itemId: itemId)?.englishSubtitleFile else { return nil }
        let url = directory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    static func metadata(_ record: DownloadRecord) -> DownloadedEpisode? {
        record.extra.flatMap { try? JSONDecoder().decode(DownloadedEpisode.self, from: $0) }
    }

    // MARK: Transfers

    /// The request for an item's original file: auth in a header (never the URL), and
    /// cellular only when the user allows it, otherwise the system waits for Wi-Fi.
    static func request(client: JellyfinClient, itemId: String, allowsCellular: Bool) -> URLRequest {
        var request = URLRequest(url: client.downloadURL(itemId: itemId))
        for (field, value) in client.playbackHeaders { request.setValue(value, forHTTPHeaderField: field) }
        request.allowsExpensiveNetworkAccess = allowsCellular
        request.allowsConstrainedNetworkAccess = allowsCellular
        return request
    }

    private func startTransfer(_ record: DownloadRecord) async {
        guard let id = record.id, let meta = Self.metadata(record) else { return }
        pausing.remove(id)
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeFile(id)) {
            try? FileManager.default.removeItem(at: resumeFile(id))
            task = session.downloadTask(withResumeData: data)
        } else {
            guard let client = makeClient() else {
                try? store.setState(id, .failed, error: "Sign in to Jellyfin to download.")
                return
            }
            task = session.downloadTask(with: Self.request(client: client, itemId: meta.itemId,
                                                           allowsCellular: DownloadSettings.load(database).allowsCellular))
        }
        task.taskDescription = "\(id)|\(meta.file)"
        task.resume()
    }

    private func handle(_ event: DownloadSessionDelegate.Event) {
        switch event {
        case .progress(let id, let done, let total):
            // A row update per half second is plenty.
            let now = Date()
            if let last = lastProgressWrite[id], now.timeIntervalSince(last) < 0.5 { return }
            lastProgressWrite[id] = now
            try? store.setProgress(id, done: done, total: total > 0 ? total : nil)
        case .finished(let id, let file, let bytes):
            lastProgressWrite[id] = nil
            try? store.finish(id, file: file, bytes: bytes)
        case .failed(let id, let message, let resumeData):
            lastProgressWrite[id] = nil
            if pausing.remove(id) != nil { return }
            if let resumeData {
                // Interrupted (network, app killed): resumable later.
                try? resumeData.write(to: resumeFile(id))
                try? store.setState(id, .paused, error: nil)
            } else {
                try? store.setState(id, .failed, error: message)
            }
        case .backgroundEventsFinished:
            backgroundEventsDone?()
            backgroundEventsDone = nil
        }
    }

    /// The Japanese transcript (for Lines and offline subtitles), the English track and the poster.
    private func saveExtras(_ meta: inout DownloadedEpisode, item: JellyfinItem, source: JellyfinMediaSource,
                            client: JellyfinClient) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let streams = source.mediaStreams ?? item.mediaStreams ?? []
        if let japanese = JellyfinSubtitlePicker.japanese(in: streams),
           let text = try? await client.subtitleText(itemId: item.id, mediaSourceId: source.id, index: japanese.index) {
            let track = SubtitleTrack(srt: text)
            if !track.cues.isEmpty {
                try? transcripts.save(
                    TranscriptInfo.make(item: item, mediaSourceId: source.id, streamIndex: japanese.index, audioIndex: meta.audioIndex),
                    lines: track.cues.map { ($0.start, $0.end, $0.text) })
            }
        }
        if let english = JellyfinSubtitlePicker.english(in: streams),
           let text = try? await client.subtitleText(itemId: item.id, mediaSourceId: source.id, index: english.index) {
            let name = "\(item.id).en.srt"
            if (try? Data(text.utf8).write(to: directory.appending(path: name))) != nil { meta.englishSubtitleFile = name }
        }
        // Intro and credits, so skipping works offline.
        _ = await MediaSegmentStore(database: database).refresh(itemId: item.id, client: client)
        let imageId = item.imageTags?["Primary"] != nil ? item.id : item.seriesId ?? item.id
        if let data = try? await http.send(client.imageRequest(itemId: imageId, maxWidth: 640)).data, !data.isEmpty {
            let name = "\(item.id).jpg"
            if (try? data.write(to: directory.appending(path: name))) != nil { meta.imageFile = name }
        }
    }

    private func task(for id: Int64) async -> URLSessionTask? {
        await session.allTasks.first { Self.recordId(of: $0) == id }
    }

    private func resumeFile(_ id: Int64) -> URL {
        directory.appending(path: "\(id).resume")
    }

    nonisolated static func recordId(of task: URLSessionTask) -> Int64? {
        task.taskDescription?.split(separator: "|").first.flatMap { Int64($0) }
    }
}

/// URLSession callbacks, off the main actor. The finished file must be moved before the
/// callback returns (the system deletes it afterwards), so that happens here.
nonisolated final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    enum Event: Sendable {
        case progress(Int64, done: Int64, total: Int64)
        case finished(Int64, file: String, bytes: Int64)
        case failed(Int64, message: String, resumeData: Data?)
        case backgroundEventsFinished
    }

    let directory: URL
    let send: @Sendable (Event) -> Void

    init(directory: URL, send: @escaping @Sendable (Event) -> Void) {
        self.directory = directory
        self.send = send
    }

    private func parts(_ task: URLSessionTask) -> (id: Int64, file: String)? {
        guard let parts = task.taskDescription?.split(separator: "|", maxSplits: 1), parts.count == 2,
              let id = Int64(parts[0]) else { return nil }
        return (id, String(parts[1]))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (id, _) = parts(downloadTask) else { return }
        send(.progress(id, done: totalBytesWritten, total: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (id, file) = parts(downloadTask) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            send(.failed(id, message: status == 401 ? "Jellyfin sign-in expired." : "Jellyfin refused the download (HTTP \(status)).",
                         resumeData: nil))
            return
        }
        let destination = directory.appending(path: file)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            send(.finished(id, file: file, bytes: bytes))
        } catch {
            send(.failed(id, message: "Couldn't save the file: \(error.localizedDescription)", resumeData: nil))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, let (id, _) = parts(task) else { return }
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        send(.failed(id, message: error.localizedDescription, resumeData: resumeData))
    }

    #if os(iOS)
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        send(.backgroundEventsFinished)
    }
    #endif
}
