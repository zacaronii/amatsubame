import Foundation
import Observation

/// Yomu's own copies of paired audiobooks (`ReadAlongAudio.folder`), downloaded one per book:
/// owned by the app, not a screen, so a download keeps going when you leave the series page and
/// a second tap shows the one running. Progress comes from the transfer; Cancel, Remove and
/// Unpair stop it first and wait for it to end, so nothing is written after a file is deleted.
@MainActor @Observable
final class ReadAlongDownloads {
    /// How far a running download is (nil until the size is known).
    private(set) var running: [String: Double?] = [:]
    /// The last word on each book's download ("Audio downloaded (…)", a failure).
    private(set) var results: [String: String] = [:]
    /// What the downloaded files take, for Settings ▸ Storage.
    private(set) var bytes: Int64 = 0
    private(set) var fileCount = 0
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored let folder: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let resolve: @MainActor (String) async -> (request: URLRequest, fileExtension: String)?

    init(folder: URL, session: URLSession = .shared,
         resolve: @escaping @MainActor (String) async -> (request: URLRequest, fileExtension: String)?) {
        self.folder = folder
        self.session = session
        self.resolve = resolve
        measure()
    }

    func localFile(itemId: String) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.deletingPathExtension().lastPathComponent == itemId }
    }

    func isRunning(_ itemId: String) -> Bool { tasks[itemId] != nil }

    /// The line under a volume's read-along row: a running download's (it needs Yomu open) wins,
    /// then how the book's last download ended, then the row's own (getting ready, Kaku).
    static func caption(running: Bool, result: String?, rowMessage: String?) -> String? {
        if running { return "Downloading the audio\u{2026} Keep Yomu open." }
        return result ?? rowMessage
    }

    /// The row has newer news than the last download's (getting ready again).
    func clearResult(itemId: String) { results[itemId] = nil }

    /// Unpairing a volume deletes its book's audio, unless another volume still reads along with
    /// that book (`pairs` of the book before unpairing).
    static func deletesAudio(unpairing chapterId: Int, pairs: [Int]) -> Bool {
        pairs.allSatisfy { $0 == chapterId }
    }

    /// Starts the book's download, unless it's running or already here.
    func start(itemId: String) {
        guard tasks[itemId] == nil, localFile(itemId: itemId) == nil else { return }
        running[itemId] = .some(nil)
        results[itemId] = nil
        tasks[itemId] = Task { await run(itemId) }
    }

    /// Stops a running download and waits until it has ended.
    func cancel(itemId: String) async {
        guard let task = tasks[itemId] else { return }
        task.cancel()
        await task.value
    }

    /// Stops it if running, then deletes the book's file.
    func delete(itemId: String) async {
        await cancel(itemId: itemId)
        if let file = localFile(itemId: itemId) { try? FileManager.default.removeItem(at: file) }
        results[itemId] = nil
        measure()
    }

    /// Settings ▸ Storage ▸ Remove: every download stopped, every file deleted.
    func deleteAll() async {
        for itemId in Array(tasks.keys) { await cancel(itemId: itemId) }
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
        results = [:]
        measure()
    }

    private func run(_ itemId: String) async {
        defer {
            running[itemId] = nil
            tasks[itemId] = nil
            measure()
        }
        guard let (request, fileExtension) = await resolve(itemId) else {
            results[itemId] = "Sign in to Audiobookshelf in Settings to download the audio."
            return
        }
        let tracker = TaskTracker()
        let progress = Task { [weak self] in
            while !Task.isCancelled {
                if let task = tracker.task, task.countOfBytesExpectedToReceive > 0 {
                    self?.running[itemId] = .some(min(Double(task.countOfBytesReceived) / Double(task.countOfBytesExpectedToReceive), 1))
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { progress.cancel() }
        do {
            let (temporary, response) = try await session.download(for: request, delegate: tracker)
            // Whatever ends this (a refusal, a late cancel), the transfer's file doesn't stay
            // behind (after a move it's no longer there).
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = folder
            try? excluded.setResourceValues(values)
            let destination = folder.appending(path: "\(itemId).\(fileExtension)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
            results[itemId] = "Audio downloaded (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))."
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                results[itemId] = nil
            } else {
                results[itemId] = "Couldn\u{2019}t download the audio: \(error.localizedDescription)"
            }
        }
    }

    private func measure() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        fileCount = files.count
        bytes = files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

/// Hands over the transfer's task, for its byte counts.
private final class TaskTracker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var created: URLSessionTask?
    var task: URLSessionTask? { lock.withLock { created } }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { created = task }
    }
}
