import Foundation

/// Thrown by a handler when retrying won't help without the user's input.
/// Any other error is treated as transient and retried with backoff.
public struct OutboxPermanentFailure: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Delivers one kind of outbox job to its server.
public protocol OutboxHandler: Sendable {
    var kind: OutboxJobKind { get }
    /// `media` are absolute file URLs in the same order as `job.media`.
    func send(_ job: OutboxJob, media: [(field: String, url: URL)]) async throws
}

public struct OutboxDrainReport: Equatable, Sendable {
    public var sent = 0
    public var retried = 0
    public var failed = 0
    public init(sent: Int = 0, retried: Int = 0, failed: Int = 0) {
        self.sent = sent
        self.retried = retried
        self.failed = failed
    }
}

/// Sends due outbox jobs through registered handlers. Kinds without a handler
/// stay pending until one is registered.
public actor OutboxWorker {
    public let store: OutboxStore
    public let mediaStorage: OutboxMediaStorage
    private var handlers: [OutboxJobKind: any OutboxHandler] = [:]
    private var isDraining = false
    private var drainRequested = false
    private var retryTask: Task<Void, Never>?
    /// When the worker will next drain on its own to retry backing-off jobs.
    public private(set) var scheduledRetry: Date?

    public init(store: OutboxStore, mediaStorage: OutboxMediaStorage, handlers: [any OutboxHandler] = []) {
        self.store = store
        self.mediaStorage = mediaStorage
        for handler in handlers { self.handlers[handler.kind] = handler }
    }

    public func register(_ handler: any OutboxHandler) {
        handlers[handler.kind] = handler
    }

    /// Call once at launch, before the first drain.
    public func recover() throws {
        try store.resetInFlight()
        try store.pruneSentProgress()
    }

    /// Sends everything that's due. If a drain is already running, it makes one
    /// more pass when done instead of running concurrently.
    /// Each kind (each server) has its own lane, so a slow Audiobookshelf doesn't hold up
    /// Anki cards, and a job is claimed only when it's about to be sent, so only that one
    /// shows as sending. Within a kind, jobs go in the order they were queued.
    @discardableResult
    public func drain() async -> OutboxDrainReport {
        var report = OutboxDrainReport()
        if isDraining {
            drainRequested = true
            return report
        }
        isDraining = true
        defer { isDraining = false }
        repeat {
            drainRequested = false
            await withTaskGroup(of: OutboxDrainReport.self) { group in
                for kind in handlers.keys {
                    group.addTask { await self.drainLane(kind) }
                }
                for await lane in group {
                    report.sent += lane.sent
                    report.retried += lane.retried
                    report.failed += lane.failed
                }
            }
        } while drainRequested
        scheduleRetry()
        return report
    }

    private func drainLane(_ kind: OutboxJobKind) async -> OutboxDrainReport {
        var report = OutboxDrainReport()
        while let claimed = try? store.claimDueJobs(kinds: [kind], limit: 1).first {
            await deliver(claimed, report: &report)
        }
        return report
    }

    /// Sleeps until the earliest backing-off job is due, then drains again, so
    /// retries happen even if nothing else (network change, new job) triggers one.
    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = nil
        guard let date = try? store.nextAttemptDate(kinds: Set(handlers.keys)) else {
            scheduledRetry = nil
            return
        }
        scheduledRetry = date
        let delay = max(date.timeIntervalSince(store.now()), 1)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.drain()
        }
    }

    private func deliver(_ claimed: ClaimedJob, report: inout OutboxDrainReport) async {
        guard let id = claimed.job.id, let handler = handlers[claimed.job.kind] else { return }
        let media = claimed.media.map { (field: $0.field, url: mediaStorage.url(for: $0.filename)) }
        do {
            try await handler.send(claimed.job, media: media)
            let files = try store.markSent(id)
            mediaStorage.remove(files)
            report.sent += 1
        } catch let failure as OutboxPermanentFailure {
            try? store.markFailed(id, error: failure.message)
            report.failed += 1
        } catch {
            try? store.markRetry(id, error: error.localizedDescription)
            report.retried += 1
        }
    }
}

/// Files attached to outbox jobs (screenshots, audio clips), kept until the job is sent.
public struct OutboxMediaStorage: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func url(for filename: String) -> URL {
        directory.appending(path: filename)
    }

    /// Writes data to a new uniquely named file and returns its filename.
    public func store(_ data: Data, fileExtension: String) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(UUID().uuidString).\(fileExtension)"
        try data.write(to: url(for: filename), options: .atomic)
        return filename
    }

    public func remove(_ filenames: [String]) {
        for filename in filenames {
            try? FileManager.default.removeItem(at: url(for: filename))
        }
    }
}
