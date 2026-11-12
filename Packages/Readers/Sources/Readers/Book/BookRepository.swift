import Foundation
import ZIPFoundation

/// Downloads each book's EPUB once and keeps it unpacked on disk, so books open
/// instantly and read offline. The least recently opened books are removed when
/// the folder grows past `limitBytes`, except books the user downloaded (pinned).
public actor BookRepository {
    public typealias Download = @Sendable (_ chapterId: Int) async throws -> Data

    public enum BookError: Error, LocalizedError {
        case unsafeEntry(String)
        case unavailable

        public var errorDescription: String? {
            switch self {
            case .unsafeEntry(let path): "The EPUB contains an unsafe file path (\(path))."
            case .unavailable: "Kavita isn't set up, and this book hasn't been downloaded."
            }
        }
    }

    public struct Book: Sendable {
        public var chapterId: Int
        public var folder: URL
        public var package: EpubPackage
    }

    public let directory: URL
    public let limitBytes: Int
    private let download: Download
    private var inFlight: [Int: Task<Book, any Error>] = [:]
    private static let marker = ".complete"
    /// Present in a downloaded book's folder: never evicted or cleared with the cache.
    private static let pinMarker = ".pinned"

    public init(directory: URL, limitBytes: Int = 1 << 30, download: @escaping Download) {
        self.directory = directory
        self.limitBytes = limitBytes
        self.download = download
    }

    public func folder(chapterId: Int) -> URL {
        directory.appending(path: String(chapterId), directoryHint: .isDirectory)
    }

    public func isDownloaded(chapterId: Int) -> Bool {
        FileManager.default.fileExists(atPath: folder(chapterId: chapterId).appending(path: Self.marker).path(percentEncoded: false))
    }

    /// The unpacked book, downloading it first if needed.
    public func book(chapterId: Int) async throws -> Book {
        if let task = inFlight[chapterId] { return try await task.value }
        let task = Task { try await load(chapterId: chapterId) }
        inFlight[chapterId] = task
        defer { inFlight[chapterId] = nil }
        return try await task.value
    }

    private func load(chapterId: Int) async throws -> Book {
        let folder = folder(chapterId: chapterId)
        let marker = folder.appending(path: Self.marker)
        if !FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) {
            let data = try await download(chapterId)
            try? FileManager.default.removeItem(at: folder)
            try Self.unpack(data, into: folder)
            FileManager.default.createFile(atPath: marker.path(percentEncoded: false), contents: nil)
            evictIfNeeded(keeping: chapterId)
        }
        // The marker's date records when the book was last opened, for eviction.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: marker.path(percentEncoded: false))
        return Book(chapterId: chapterId, folder: folder, package: try EpubPackage.parse(folder: folder))
    }

    /// Unzips into `folder`, refusing entries that would land outside it.
    static func unpack(_ data: Data, into folder: URL) throws {
        let archive = try Archive(data: data, accessMode: .read)
        let root = folder.standardizedFileURL.path(percentEncoded: false)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in archive {
            let destination = folder.appending(path: entry.path).standardizedFileURL
            guard destination.path(percentEncoded: false).hasPrefix(root), !entry.path.hasPrefix("/") else {
                try? FileManager.default.removeItem(at: folder)
                throw BookError.unsafeEntry(entry.path)
            }
            guard entry.type == .file else { continue }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: destination, skipCRC32: false)
        }
    }

    /// Removes the least recently opened books until the folder fits the limit.
    func evictIfNeeded(keeping chapterId: Int) {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        var books = folders.compactMap { folder -> (url: URL, opened: Date, bytes: Int)? in
            guard Int(folder.lastPathComponent) != chapterId, !Self.isPinned(folder),
                  let attributes = try? manager.attributesOfItem(atPath: folder.appending(path: Self.marker).path(percentEncoded: false))
            else { return nil }
            return (folder, attributes[.modificationDate] as? Date ?? .distantPast, Self.size(of: folder))
        }
        // Downloaded books don't count against the cache limit.
        var total = books.reduce(0) { $0 + $1.bytes } + (Self.isPinned(folder(chapterId: chapterId)) ? 0 : Self.size(of: folder(chapterId: chapterId)))
        books.sort { $0.opened < $1.opened }
        for book in books where total > limitBytes {
            try? manager.removeItem(at: book.url)
            total -= book.bytes
        }
    }

    /// Characters per section of a book that's already on the device (never downloads),
    /// for progress outside the reader. Nil for books not opened or downloaded here.
    public func cachedTextIndex(chapterId: Int) -> BookTextIndex? {
        guard isDownloaded(chapterId: chapterId) else { return nil }
        let folder = folder(chapterId: chapterId)
        guard let package = try? EpubPackage.parse(folder: folder) else { return nil }
        return BookTextIndex.load(folder: folder, package: package)
    }

    public func totalBytes() -> Int {
        Self.size(of: directory)
    }

    // MARK: Downloads

    /// Keeps a book on the device (a download): eviction and Clear skip it.
    public func pin(chapterId: Int) {
        FileManager.default.createFile(atPath: folder(chapterId: chapterId).appending(path: Self.pinMarker).path(percentEncoded: false),
                                       contents: nil)
    }

    /// Turns a download back into ordinary cache (it may then be evicted).
    public func unpin(chapterId: Int) {
        try? FileManager.default.removeItem(at: folder(chapterId: chapterId).appending(path: Self.pinMarker))
        evictIfNeeded(keeping: -1)
    }

    public func isPinned(chapterId: Int) -> Bool {
        Self.isPinned(folder(chapterId: chapterId))
    }

    /// Deletes one book from the device, downloaded or cached.
    public func remove(chapterId: Int) {
        try? FileManager.default.removeItem(at: folder(chapterId: chapterId))
    }

    public func bytes(chapterId: Int) -> Int {
        Self.size(of: folder(chapterId: chapterId))
    }

    /// Opened books that aren't downloads (what Clear would free).
    public func unpinnedBytes() -> Int {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { !Self.isPinned($0) }.reduce(0) { $0 + Self.size(of: $1) }
    }

    /// Removes cached books, keeping downloads.
    public func clear() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !Self.isPinned(folder) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    static func isPinned(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: pinMarker).path(percentEncoded: false))
    }

    static func size(of folder: URL) -> Int {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let file = enumerator?.nextObject() as? URL {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
