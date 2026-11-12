import CoreGraphics
import Foundation
import ImageIO

/// Covers are fetched with header auth (no secrets in the URL), so a regular
/// URL cache is safe and keeps them available offline.
nonisolated public enum CoverLoader {
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 20 << 20, diskCapacity: 200 << 20)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: configuration)
    }()

    public static func image(for request: URLRequest, maxPixelSize: Int) async throws -> CGImage? {
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
