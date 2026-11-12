import CoreGraphics
import Foundation
import ImageIO

/// Cache-first OCR for manga pages, shared by every reader. Loads the models on
/// first use and makes sure a page is never processed twice at once.
public actor OCRService {
    public let cache: OCRCache
    let storeDirectory: URL
    let computeUnits: OCRComputeUnits
    private var pipeline: OCRPipeline?
    private var inFlight: [PageKey: Task<OCRResult, any Error>] = [:]

    struct PageKey: Hashable {
        var chapterId: Int
        var page: Int
    }

    public struct OCRResult: Sendable {
        public var page: OCRPage
        /// Nil when the result came from the cache.
        public var timings: OCRTimings?
    }

    public init(cache: OCRCache, storeDirectory: URL, computeUnits: OCRComputeUnits = .default) {
        self.cache = cache
        self.storeDirectory = storeDirectory
        self.computeUnits = computeUnits
    }

    public var modelsInstalled: Bool { OCRModelStore.isInstalled(in: storeDirectory) }

    public func cachedPage(chapterId: Int, page: Int) -> OCRPage? {
        cache.page(chapterId: chapterId, page: page)
    }

    /// The page's text blocks, from the cache or by running OCR on `imageData`.
    public func page(chapterId: Int, page: Int, imageData: Data) async throws -> OCRResult {
        if let cached = cache.page(chapterId: chapterId, page: page) { return OCRResult(page: cached, timings: nil) }
        let key = PageKey(chapterId: chapterId, page: page)
        if let task = inFlight[key] { return try await task.value }
        let pipeline = try loadedPipeline()
        let cache = cache
        let task = Task<OCRResult, any Error> {
            let image = try Self.decode(imageData)
            let (result, timings) = try await pipeline.recognize(page: image)
            try? cache.store(result, chapterId: chapterId, page: page)
            return OCRResult(page: result, timings: timings)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// Reads a region the user drew on a page.
    public func recognize(region: NormalizedRect, imageData: Data) async throws -> OCRBlock {
        let pipeline = try loadedPipeline()
        return try await pipeline.recognize(region: region, in: try Self.decode(imageData))
    }

    /// Forget the loaded models (after they're deleted or replaced).
    public func unloadModels() {
        pipeline = nil
    }

    private func loadedPipeline() throws -> OCRPipeline {
        if let pipeline { return pipeline }
        guard modelsInstalled else { throw OCRError.modelsNotInstalled }
        let loaded = try OCRPipeline(modelDirectory: storeDirectory.appending(path: "compiled"), computeUnits: computeUnits)
        pipeline = loaded
        return loaded
    }

    static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw OCRError.imageConversionFailed
        }
        return image
    }
}
