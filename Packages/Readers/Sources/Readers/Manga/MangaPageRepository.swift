import Core
import CoreGraphics
import Foundation
import ImageIO
import KavitaKit

/// Where page images and dimensions come from when they aren't cached.
public protocol MangaPageSource: Sendable {
    func dimensions(chapterId: Int) async throws -> [KavitaPageDimension]
    func pageData(chapterId: Int, page: Int) async throws -> Data
    func serverProgress(chapterId: Int) async throws -> KavitaServerProgress
}

public struct KavitaPageSource: MangaPageSource {
    public let client: KavitaClient

    public init(client: KavitaClient) {
        self.client = client
    }

    public func dimensions(chapterId: Int) async throws -> [KavitaPageDimension] {
        try await client.fileDimensions(chapterId: chapterId)
    }

    public func pageData(chapterId: Int, page: Int) async throws -> Data {
        try await client.pageImage(chapterId: chapterId, page: page)
    }

    public func serverProgress(chapterId: Int) async throws -> KavitaServerProgress {
        try await client.progress(chapterId: chapterId)
    }
}

public enum MangaPageError: Error, LocalizedError, Equatable {
    case notConfigured
    case undecodable

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Kavita isn't set up. Add it in Settings."
        case .undecodable: "This page couldn't be decoded."
        }
    }
}

/// Cache-first access to pages, shared by every reader so downloads are
/// deduplicated and prefetches reuse in-flight requests.
public actor MangaPageRepository {
    private let cache: PageCacheStore
    private let source: @Sendable () -> (any MangaPageSource)?
    private var inFlight: [PageCacheKey: Task<Data, any Error>] = [:]
    private var prefetchTask: Task<Void, Never>?

    public init(cache: PageCacheStore, source: @escaping @Sendable () -> (any MangaPageSource)?) {
        self.cache = cache
        self.source = source
    }

    public func dimensions(chapterId: Int) async throws -> [KavitaPageDimension] {
        let key = PageCacheKey.dimensions(chapterId: chapterId)
        if let data = cache.data(for: key), let cached = try? JSONDecoder().decode([KavitaPageDimension].self, from: data) {
            return cached
        }
        guard let source = source() else { throw MangaPageError.notConfigured }
        let dimensions = try await source.dimensions(chapterId: chapterId)
        try? cache.store(JSONEncoder().encode(dimensions), for: key)
        return dimensions
    }

    public func serverProgress(chapterId: Int) async throws -> KavitaServerProgress {
        guard let source = source() else { throw MangaPageError.notConfigured }
        return try await source.serverProgress(chapterId: chapterId)
    }

    public func pageData(chapterId: Int, page: Int) async throws -> Data {
        let key = PageCacheKey(chapterId: chapterId, page: page)
        if let data = cache.data(for: key) { return data }
        if let task = inFlight[key] { return try await task.value }
        guard let source = source() else { throw MangaPageError.notConfigured }
        let cache = cache
        let task = Task<Data, any Error> {
            let data = try await source.pageData(chapterId: chapterId, page: page)
            try? cache.store(data, for: key)
            return data
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// Downloads pages in order, one at a time, replacing any earlier prefetch.
    public func prefetch(chapterId: Int, pages: [Int]) {
        prefetchTask?.cancel()
        let missing = pages.filter { !cache.contains(PageCacheKey(chapterId: chapterId, page: $0)) }
        guard !missing.isEmpty else { return }
        prefetchTask = Task {
            for page in missing {
                if Task.isCancelled { return }
                _ = try? await pageData(chapterId: chapterId, page: page)
            }
        }
    }

    /// Decodes and downsamples page data off the main thread.
    public nonisolated static func decodeImage(_ data: Data, maxPixelSize: Int) async throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw MangaPageError.undecodable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MangaPageError.undecodable
        }
        return image
    }
}
