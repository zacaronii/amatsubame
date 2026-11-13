import CoreGraphics
import Foundation
import ImageIO
import Observation
import Synchronization

/// Covers are fetched with header auth (no secrets in the URL), so a URL cache is safe and
/// keeps them available offline. Only images are cached (never an error page), and a cached
/// cover is checked with the server once per launch (`If-Modified-Since`/`If-None-Match`),
/// so a cover changed on the server shows up without clearing anything.
nonisolated public enum CoverLoader {
    /// The same cache as before covers were checked, so existing covers stay.
    static let cache = URLCache(memoryCapacity: 20 << 20, diskCapacity: 200 << 20)

    /// The session never caches by itself: `data(for:)` decides what to keep.
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Covers checked with the server since launch (or since the last `recheck()`).
    private static let checked = Mutex<Set<String>>([])

    /// Shows the cached cover at once, then the server's if it changed (the first time this
    /// launch). `update` gets each image to show.
    public static func load(_ request: URLRequest, maxPixelSize: Int, update: @MainActor (CGImage) -> Void) async {
        let cached = cachedData(for: request)
        if let cached, let image = thumbnail(cached, maxPixelSize: maxPixelSize) { await update(image) }
        guard let fresh = try? await data(for: request), fresh != cached,
              let image = thumbnail(fresh, maxPixelSize: maxPixelSize) else { return }
        await update(image)
    }

    /// The cover now: cached, or from the server.
    public static func image(for request: URLRequest, maxPixelSize: Int) async throws -> CGImage? {
        try await data(for: request).flatMap { thumbnail($0, maxPixelSize: maxPixelSize) }
    }

    /// The cover's data, checked with the server once per launch. Offline, the cached copy.
    public static func data(for request: URLRequest) async throws -> Data? {
        try await data(for: request, session: session, cache: cache)
    }

    static func data(for request: URLRequest, session: URLSession, cache: URLCache) async throws -> Data? {
        guard let key = request.url?.absoluteString else { return nil }
        let cached = cache.cachedResponse(for: request).flatMap { isImage($0.response, $0.data) ? $0 : nil }
        if let cached, checked.withLock({ $0.contains(key) }) { return cached.data }

        var conditional = request
        if let response = cached?.response as? HTTPURLResponse {
            if let date = response.value(forHTTPHeaderField: "Last-Modified") {
                conditional.setValue(date, forHTTPHeaderField: "If-Modified-Since")
            }
            if let tag = response.value(forHTTPHeaderField: "ETag") {
                conditional.setValue(tag, forHTTPHeaderField: "If-None-Match")
            }
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: conditional)
        } catch {
            if let cached { return cached.data }
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 304, let cached {
            checked.withLock { _ = $0.insert(key) }
            return cached.data
        }
        if isImage(response, data) {
            cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
            checked.withLock { _ = $0.insert(key) }
            return data
        }
        // The cover is gone (404); anything else (a server error) keeps what we had.
        if status == 404 {
            cache.removeCachedResponse(for: request)
            checked.withLock { _ = $0.insert(key) }
            return nil
        }
        return cached?.data
    }

    /// The cached cover, if it's an image (older versions also cached error responses).
    static func cachedData(for request: URLRequest) -> Data? {
        cache.cachedResponse(for: request).flatMap { isImage($0.response, $0.data) ? $0.data : nil }
    }

    /// Check every cover with the server again (pull to refresh); covers on screen reload.
    @MainActor public static func recheck() {
        forgetChecks()
        CoverGeneration.shared.value += 1
    }

    static func forgetChecks() {
        checked.withLock { $0.removeAll() }
    }

    static func isImage(_ response: URLResponse, _ data: Data) -> Bool {
        (response as? HTTPURLResponse)?.statusCode == 200 && CGImageSourceCreateWithData(data as CFData, nil)
            .map { CGImageSourceGetCount($0) > 0 } == true
    }

    static func thumbnail(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Bumped by `CoverLoader.recheck()`: cover views include it in their task's id, so they
/// load again after a pull to refresh.
@MainActor @Observable
public final class CoverGeneration {
    public static let shared = CoverGeneration()
    public internal(set) var value = 0
}
