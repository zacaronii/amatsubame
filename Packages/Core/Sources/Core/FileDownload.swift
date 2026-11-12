import Foundation

/// A file downloaded in the foreground with progress (recommended dictionaries, OCR models).
public enum FileDownload {
    /// Downloads `url` into `folder` (created if needed) and returns the file. `progress` gets
    /// the bytes so far and the expected total when the server says.
    public static func download(
        _ url: URL, into folder: URL, session: URLSession = .shared,
        progress: @escaping @Sendable (_ written: Int64, _ expected: Int64?) -> Void = { _, _ in }
    ) async throws -> URL {
        let (temporary, response) = try await session.download(from: url, delegate: ProgressDelegate(onProgress: progress))
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: temporary)
            throw ConnectionError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: "\(UUID().uuidString).\(url.pathExtension.isEmpty ? "download" : url.pathExtension)")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

/// Reports a download task's progress (the async `download(from:delegate:)` API).
public final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let onProgress: @Sendable (Int64, Int64?) -> Void

    public init(onProgress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.onProgress = onProgress
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
