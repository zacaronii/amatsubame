import AudiobookshelfKit
import Core
import Foundation
import Observation

/// What's saved with a downloaded episode so it plays, shows its transcript and mines offline.
struct DownloadedAudio: Codable, Equatable {
    var itemId: String
    var episodeId: String
    var title: String
    var showTitle: String
    var duration: Double?
    var publishedAt: Double?
    var ino: String
    /// The audio file's name in the downloads folder.
    var file: String
    var imageFile: String?

    var key: String { AudiobookshelfProgress.key(itemId: itemId, episodeId: episodeId) }
}

/// Downloads episodes with a background URLSession, so they continue while the app is in the
/// background. Records live in `DownloadStore`; files in `directory`. Like Miru's downloader.
@MainActor @Observable
final class EpisodeDownloader {
    static let sessionIdentifier = "com.amatsubame.kiku.downloads"

    /// Every episode download, by episode key (kept current from the store).
    private(set) var records: [String: DownloadRecord] = [:]
    private(set) var lastError: String?
    let directory: URL

    @ObservationIgnored private let store: DownloadStore
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let makeClient: @MainActor () -> AudiobookshelfClient?
    /// Saves the episode's transcript from Kaku with the audio (nil when Kaku isn't set up).
    @ObservationIgnored private let saveTranscript: @MainActor (EpisodeEntry) async -> Void
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var pausing: Set<Int64> = []
    @ObservationIgnored private var lastProgressWrite: [Int64: Date] = [:]
    @ObservationIgnored private var backgroundEventsDone: (() -> Void)?

    init(directory: URL, store: DownloadStore, database: AppDatabase, background: Bool = true,
         makeClient: @escaping @MainActor () -> AudiobookshelfClient?, saveTranscript: @escaping @MainActor (EpisodeEntry) async -> Void) {
        self.directory = directory
        self.store = store
        self.database = database
        self.makeClient = makeClient
        self.saveTranscript = saveTranscript
        let configuration = background
            ? URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
            : URLSessionConfiguration.default
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        let delegate = AudioDownloadDelegate(directory: directory) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    // MARK: Lifecycle

    func start() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        await reconcile()
        do {
            for try await all in store.observe(kind: .audiobookshelfEpisode) {
                records = Dictionary(all.map { ($0.itemKey, $0) }, uniquingKeysWith: { $1 })
            }
        } catch {}
    }

    private func reconcile() async {
        let tasks = await session.allTasks
        let live = Set(tasks.compactMap { Self.recordId(of: $0) })
        for record in (try? store.all(kind: .audiobookshelfEpisode)) ?? [] where record.isActive {
            guard let id = record.id, !live.contains(id) else { continue }
            if FileManager.default.fileExists(atPath: resumeFile(id).path(percentEncoded: false)) {
                try? store.setState(id, .paused)
            } else {
                await startTransfer(record)
            }
        }
    }

    func handleBackgroundEvents() async {
        await withCheckedContinuation { continuation in
            backgroundEventsDone = { continuation.resume() }
        }
    }

    // MARK: Actions

    /// Downloads an episode: the transcript and cover first (small), then the audio.
    func download(_ entry: EpisodeEntry) async {
        guard let client = makeClient() else {
            lastError = "Sign in to Audiobookshelf to download."
            return
        }
        if let existing = records[entry.id], existing.state == .done || existing.isActive { return }
        guard let audio = entry.episode.audioFile else {
            lastError = "Audiobookshelf has no audio file for \(entry.episode.title)."
            return
        }
        let ext = audio.fileExtension
        var meta = DownloadedAudio(itemId: entry.itemId, episodeId: entry.episode.id, title: entry.episode.title,
                                   showTitle: entry.showTitle, duration: entry.episode.length, publishedAt: entry.episode.publishedAt,
                                   ino: audio.ino, file: "\(entry.itemId)-\(entry.episode.id).\(ext)")
        await saveTranscript(entry)
        if let request = try? await client.coverRequest(itemId: entry.itemId, width: 600),
           let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
            let name = "\(entry.itemId).jpg"
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? data.write(to: directory.appending(path: name))) != nil { meta.imageFile = name }
        }
        do {
            let record = try store.enqueue(DownloadRecord(
                kind: .audiobookshelfEpisode, itemKey: entry.id, seriesKey: entry.itemId, seriesTitle: entry.collectionTitle,
                title: entry.episode.title, detail: entry.episode.publishedDate.map { EpisodeEntry.dayText($0) },
                bytesTotal: entry.episode.size.map(Int64.init), extra: try JSONEncoder().encode(meta), createdAt: Date()))
            await startTransfer(record)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

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

    /// Removes the download and its files (the saved transcript stays for search).
    func delete(_ record: DownloadRecord) async {
        guard let id = record.id else { return }
        pausing.insert(id)
        await task(for: id)?.cancel()
        if let meta = Self.metadata(record) {
            try? FileManager.default.removeItem(at: directory.appending(path: meta.file))
            // The cover is shared by the show's episodes: only the last one takes it.
            if let image = meta.imageFile, !records.values.contains(where: { $0.id != id && Self.metadata($0)?.imageFile == image }) {
                try? FileManager.default.removeItem(at: directory.appending(path: image))
            }
        }
        try? FileManager.default.removeItem(at: resumeFile(id))
        try? store.remove(id)
    }

    // MARK: Lookups

    /// The downloaded audio for an episode key, if it's complete and on the device.
    func localFile(key: String) -> URL? {
        guard let record = records[key] ?? (try? store.download(kind: .audiobookshelfEpisode, itemKey: key)) ?? nil,
              record.state == .done, let meta = Self.metadata(record) else { return nil }
        let url = directory.appending(path: meta.file)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Shows with a finished download (the Library's Downloaded filter).
    var downloadedShowIds: Set<String> {
        Set(records.values.filter { $0.state == .done }.compactMap(\.seriesKey))
    }

    static func metadata(_ record: DownloadRecord) -> DownloadedAudio? {
        record.extra.flatMap { try? JSONDecoder().decode(DownloadedAudio.self, from: $0) }
    }

    // MARK: Transfers

    private func startTransfer(_ record: DownloadRecord) async {
        guard let id = record.id, var meta = Self.metadata(record) else { return }
        // Downloads queued before 2026-11-05 named the file after Audiobookshelf's format
        // description ("…mp2/3 (mpeg audio layer 2/3)"), whose "/" made saving fail.
        if meta.file.contains("/") {
            meta.file = "\(meta.itemId)-\(meta.episodeId).\(meta.file.contains("mpeg-4") ? "m4a" : "mp3")"
            try? store.setExtra(id, try? JSONEncoder().encode(meta))
        }
        pausing.remove(id)
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeFile(id)) {
            try? FileManager.default.removeItem(at: resumeFile(id))
            task = session.downloadTask(withResumeData: data)
        } else {
            guard let client = makeClient(), var request = try? await client.audioRequest(itemId: meta.itemId, ino: meta.ino) else {
                try? store.setState(id, .failed, error: "Sign in to Audiobookshelf to download.")
                return
            }
            // Cellular only when allowed; otherwise the system waits for Wi-Fi.
            let cellular = DownloadSettings.load(database).allowsCellular
            request.allowsExpensiveNetworkAccess = cellular
            request.allowsConstrainedNetworkAccess = cellular
            task = session.downloadTask(with: request)
        }
        task.taskDescription = "\(id)|\(meta.file)"
        task.resume()
    }

    private func handle(_ event: AudioDownloadDelegate.Event) {
        switch event {
        case .progress(let id, let done, let total):
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

/// URLSession callbacks, off the main actor. The finished file is moved before the callback
/// returns (the system deletes it afterwards).
nonisolated final class AudioDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
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
            send(.failed(id, message: status == 401 ? "Audiobookshelf sign-in expired." : "Audiobookshelf refused the download (HTTP \(status)).",
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
