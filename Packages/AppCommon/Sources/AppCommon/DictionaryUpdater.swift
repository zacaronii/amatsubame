import Core
import Dictionary
import Foundation
import Lookup
import Observation

/// Installs the recommended dictionaries and keeps self-updating ones current. A dictionary updates when it came from the recommended set or
/// its `index.json` says `isUpdatable`; imported ones are otherwise left alone. To update:
/// fetch its `indexUrl`, and when the revision there differs from the installed zip's,
/// download the new zip beside the old one and swap it in (same id, order and on/off).
@Observable
public final class DictionaryUpdater {
    public enum ItemState: Equatable, Sendable {
        case waiting
        case downloading(Double?)
        case installing
        case installed
        case failed(String)
    }

    /// The recommended set's progress while it installs, by catalog id.
    public private(set) var items: [String: ItemState] = [:]
    public private(set) var isInstalling = false
    public private(set) var isChecking = false
    /// The last check's outcome for Settings ("Updated Jitendex", "Everything is up to date").
    public private(set) var lastResult: String?

    @ObservationIgnored private let library: DictionaryLibrary
    @ObservationIgnored private let lookup: LookupService
    @ObservationIgnored private let reachability: Reachability
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let downloads: URL
    /// Shared setups: one app updates at a time.
    @ObservationIgnored private let lockFile: URL
    @ObservationIgnored private var started = false
    /// Off where the dictionaries aren't the app's to change (Hiku's own setup: the
    /// extension's built-in ones).
    @ObservationIgnored public var isEnabled = true

    static let checkInterval: TimeInterval = 7 * 24 * 3600
    static let lockLifetime: TimeInterval = 3600

    init(library: DictionaryLibrary, lookup: LookupService, reachability: Reachability, session: URLSession = .shared) {
        self.library = library
        self.lookup = lookup
        self.reachability = reachability
        self.session = session
        // This app's own temporary folder, even when the dictionaries are shared.
        downloads = FileManager.default.temporaryDirectory.appending(path: "DictionaryDownloads", directoryHint: .isDirectory)
        lockFile = library.directory.appending(path: ".update-lock")
    }

    // MARK: What's installed

    /// Recommended dictionaries already installed, by catalog id (from the recommended set,
    /// or one with the same name imported from Files).
    public func installedRecommended() -> Set<String> {
        let sources = (try? library.sources()) ?? [:]
        return Set(((try? library.dictionaries()) ?? []).compactMap {
            RecommendedDictionaries.entry(for: $0, source: sources[$0.id])?.id
        })
    }

    /// Recommended dictionaries the user deleted: never installed again unasked.
    public func removedRecommended() -> Set<String> {
        Set((try? library.settings().removedRecommended) ?? [])
    }

    /// The installed dictionaries that update themselves (the "Auto" badge).
    public func selfUpdating() -> Set<String> {
        let sources = (try? library.sources()) ?? [:]
        return Set(sources.values.filter(\.updates).map(\.dictionaryId))
    }

    // MARK: Launch

    /// At launch: tidies leftovers and records where already-installed dictionaries came from;
    /// then checks weekly while the app runs.
    func start() {
        guard isEnabled, !started else { return }
        started = true
        cleanUp()
        Task {
            await adoptInstalled()
            #if DEBUG
            // UI tests: an installed recommended dictionary looks out of date, for Check Now.
            if let catalogId = ProcessInfo.processInfo.environment["UITEST_STALE_DICTIONARY"] {
                try? await library.database.writer.write { db in
                    try db.execute(sql: "UPDATE dictionary SET revision = 'stale' WHERE id IN (SELECT dictionaryId FROM dictionarySource WHERE catalogId = ?)",
                                   arguments: [catalogId])
                    try db.execute(sql: "UPDATE dictionarySource SET undeliveredRevision = NULL WHERE catalogId = ?", arguments: [catalogId])
                }
            }
            #endif
            while !Task.isCancelled {
                await checkForUpdates(automatic: true)
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// Half-finished downloads and imports, and a lock left by an app that stopped mid-update.
    private func cleanUp() {
        try? FileManager.default.removeItem(at: downloads)
        library.removeUnfinishedImports()
        if let date = lockDate(), Date().timeIntervalSince(date) > Self.lockLifetime {
            try? FileManager.default.removeItem(at: lockFile)
        }
    }

    /// Dictionaries installed before sources were recorded (or imported from Files): their
    /// update address from their own `index.json`, and their recommended entry by name.
    func adoptInstalled() async {
        let sources = (try? library.sources()) ?? [:]
        for record in (try? library.dictionaries()) ?? [] where sources[record.id] == nil {
            let index = library.installedIndex(of: record)
            let source = DictionarySource(
                dictionaryId: record.id, catalogId: RecommendedDictionaries.entry(for: record, source: nil)?.id,
                indexUrl: index?.indexUrl, downloadUrl: index?.downloadUrl, isUpdatable: index?.isUpdatable ?? false)
            try? await library.saveSource(source)
        }
    }

    // MARK: Installing the recommended set

    /// Downloads and installs recommended dictionaries one at a time, in the set's order,
    /// skipping ones already installed. Allowed on cellular: the user asked for them.
    public func installRecommended(_ ids: [String]) async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        let installed = installedRecommended()
        let wanted = RecommendedDictionaries.all.filter { ids.contains($0.id) }
        for entry in wanted where !installed.contains(entry.id) { items[entry.id] = .waiting }
        var downloaded = false
        for entry in wanted {
            if installed.contains(entry.id) { items[entry.id] = .installed; continue }
            do {
                try await install(entry)
                items[entry.id] = .installed
                downloaded = true
            } catch {
                guard !error.isCancellation else { items[entry.id] = nil; return }
                items[entry.id] = .failed(error.localizedDescription)
                AppLog.error(.dictionaries, "Couldn't install \(entry.name): \(error.localizedDescription)")
            }
        }
        // Just downloaded, so they're the latest: that counts as a check.
        if downloaded { try? await library.updateSettings { $0.lastUpdateCheck = Date() } }
    }

    private func install(_ entry: RecommendedDictionary) async throws {
        items[entry.id] = .downloading(nil)
        let zip = try await FileDownload.download(entry.downloadURL, into: downloads, session: session) { [weak self] written, expected in
            let fraction = expected.map { Double(written) / Double($0) }
            Task { @MainActor in self?.items[entry.id] = .downloading(fraction) }
        }
        defer { try? FileManager.default.removeItem(at: zip) }
        items[entry.id] = .installing
        do {
            let outcome = try await library.importDictionary(at: zip, catalogId: entry.id)
            AppLog.info(.dictionaries, "Installed \(outcome.dictionary.title)")
            // Unforgotten if it had been deleted before: the user asked for it again.
            try? await library.updateSettings { $0.removedRecommended.removeAll { $0 == entry.id } }
            if entry.id == RecommendedDictionaries.frequency, (try? library.settings().frequencySortTitle) == nil {
                try? await library.setFrequencySortDictionary(outcome.dictionary.title)
            }
        } catch DictionaryError.alreadyInstalled {
            // Imported separately under the same name: it counts as installed.
        }
        try? await lookup.reload()
    }

    // MARK: Updates

    public var autoUpdate: Bool {
        get { (try? library.settings().autoUpdate) ?? true }
        set {
            Task { try? await library.updateSettings { $0.autoUpdate = newValue } }
        }
    }

    public var lastCheck: Date? { try? library.settings().lastUpdateCheck }

    /// Checks every self-updating dictionary and installs newer revisions. `automatic`: the
    /// weekly check, only on Wi-Fi outside Low Data Mode, and only while Keep Recommended Up
    /// to Date is on; Check Now runs whenever asked.
    public func checkForUpdates(automatic: Bool = false) async {
        guard !isChecking, !isInstalling else { return }
        if automatic {
            guard autoUpdate, reachability.isOnline, !reachability.isExpensive else { return }
            if let last = lastCheck, Date().timeIntervalSince(last) < Self.checkInterval { return }
        }
        guard takeLock() else { return }
        defer { releaseLock() }
        isChecking = true
        defer { isChecking = false }

        let sources = (try? library.sources()) ?? [:]
        var updated: [String] = [], failed: [String] = []
        for record in (try? library.dictionaries()) ?? [] {
            guard let source = sources[record.id], source.updates, let indexURL = source.indexUrl.flatMap(URL.init(string:)) else { continue }
            do {
                if let title = try await update(record, source: source, indexURL: indexURL) { updated.append(title) }
            } catch {
                guard !error.isCancellation else { return }
                failed.append(record.title)
                AppLog.error(.dictionaries, "Couldn't update \(record.title): \(error.localizedDescription)")
            }
        }
        try? await library.updateSettings { $0.lastUpdateCheck = Date() }
        if !updated.isEmpty { try? await lookup.reload() }
        lastResult = if !failed.isEmpty {
            "Couldn't check \(failed.joined(separator: ", "))."
        } else if updated.isEmpty {
            "Everything is up to date."
        } else {
            "Updated \(updated.joined(separator: ", "))."
        }
        AppLog.info(.dictionaries, "Update check: \(lastResult ?? "")")
    }

    /// Updates one dictionary when its index names a different revision; returns its new title.
    private func update(_ record: DictionaryRecord, source: DictionarySource, indexURL: URL) async throws -> String? {
        var source = source
        let (data, response) = try await session.data(from: indexURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ConnectionError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let remote = try JSONDecoder().decode(DictionaryIndex.self, from: data)
        source.checkedAt = Date()
        // The same revision, or one a download already failed to bring (a stale mirror).
        guard let revision = remote.revision, revision != record.revision, revision != source.undeliveredRevision,
              let download = (remote.downloadUrl ?? source.downloadUrl).flatMap(URL.init(string:))
                ?? source.catalogId.flatMap(RecommendedDictionaries.entry)?.downloadURL
        else {
            try await library.saveSource(source)
            return nil
        }
        let zip = try await FileDownload.download(download, into: downloads, session: session)
        defer { try? FileManager.default.removeItem(at: zip) }
        do {
            let outcome = try await library.importDictionary(at: zip, replacing: record.id)
            AppLog.info(.dictionaries, "Updated \(record.title) (\(record.revision ?? "?")) to \(outcome.dictionary.revision ?? "?")")
            return outcome.dictionary.title
        } catch DictionaryError.alreadyInstalled {
            // The download still had the old revision: don't fetch it again until the index
            // names a newer one.
            source.undeliveredRevision = revision
            try await library.saveSource(source)
            AppLog.info(.dictionaries, "\(record.title): the download was still \(record.revision ?? "?"), not \(revision)")
            return nil
        }
    }

    // MARK: One app at a time

    private func lockDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: lockFile.path(percentEncoded: false)))?[.modificationDate] as? Date
    }

    private func takeLock() -> Bool {
        if let date = lockDate(), Date().timeIntervalSince(date) < Self.lockLifetime { return false }
        try? FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
        return FileManager.default.createFile(atPath: lockFile.path(percentEncoded: false), contents: Data(ProcessInfo.processInfo.processName.utf8))
    }

    private func releaseLock() {
        try? FileManager.default.removeItem(at: lockFile)
    }
}
