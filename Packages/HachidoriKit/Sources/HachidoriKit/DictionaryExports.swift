import Foundation
import ZIPFoundation

/// The host's dictionaries as files (docs/hachidori.md section 7), over its Yomitan API (port
/// 19633), not the link. A download is a stored ZIP64 holding the compiled hoshidicts folder
/// (`dictionaries/0/`) and `hachidori-backup.json`. That file also carries the host's settings,
/// its AnkiConnect key included, so only the folder is ever unpacked.
public struct HostDictionaryExports: Sendable {
    /// The Yomitan API's port in Hachidori and hachidori-docker.
    public static let apiPort = 19633

    /// One dictionary the host can export (`GET /dictionaries`).
    public struct Export: Decodable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var revision: String?
        public var fileName: String?

        public init(id: String, title: String, revision: String? = nil, fileName: String? = nil) {
            self.id = id
            self.title = title
            self.revision = revision
            self.fileName = fileName
        }
    }

    public let baseURL: URL
    let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// `http://<host>:19633` for a link URL's host (`wss` links get `https`).
    public static func apiURL(forLink link: URL, port: Int = apiPort) -> URL? {
        guard let host = link.host(percentEncoded: false), !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = link.scheme == "wss" ? "https" : "http"
        components.host = host
        components.port = port
        return components.url
    }

    /// The dictionaries the host has, in no particular order (`dictionaryState` has the order).
    public func list() async throws(HachidoriError) -> [Export] {
        struct Reply: Decodable { var dictionaries: [Export] }
        let data = try await get(baseURL.appending(path: "dictionaries"))
        do {
            return try JSONDecoder().decode(Reply.self, from: data).dictionaries
        } catch {
            throw .malformed("an unreadable dictionary list")
        }
    }

    /// Downloads dictionary `id` to `file` (replacing it), reporting the fraction done.
    public func download(_ id: String, to file: URL,
                         progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws(HachidoriError) {
        let url = baseURL.appending(path: "dictionaries").appending(path: id)
        let downloaded: URL
        let response: URLResponse
        do {
            (downloaded, response) = try await session.download(from: url, delegate: DownloadProgress(progress))
        } catch {
            throw Self.error(error)
        }
        try Self.check(response)
        do {
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: downloaded, to: file)
        } catch {
            throw .malformed("the download couldn't be saved: \(error.localizedDescription)")
        }
    }

    /// Unpacks the compiled folder of a downloaded export into `folder` (created), skipping
    /// `hachidori-backup.json` and anything outside the one dictionary folder.
    public static func unpack(_ archiveFile: URL, into folder: URL) throws(HachidoriError) {
        let archive: Archive
        do {
            archive = try Archive(url: archiveFile, accessMode: .read)
        } catch {
            throw .malformed("the dictionary download isn't a ZIP")
        }
        guard let prefix = archive.lazy.map(\.path).compactMap(Self.dictionaryFolder).first else {
            throw .malformed("the dictionary download has no dictionary folder")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for entry in archive where entry.type == .file && entry.path.hasPrefix(prefix) {
                let relative = String(entry.path.dropFirst(prefix.count))
                let parts = relative.split(separator: "/")
                guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { continue }
                let destination = folder.appending(path: relative)
                if relative.hasPrefix(".hoshidicts_") {
                    // The format marker is empty, but Hachidori's ZIP64 entry for it reads as
                    // 4 GiB here, and extracting it copies the rest of the archive into it.
                    FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: Data())
                    continue
                }
                _ = try archive.extract(entry, to: destination)
            }
        } catch {
            throw .malformed("the dictionary download couldn't be unpacked: \(error.localizedDescription)")
        }
    }

    /// `dictionaries/<n>/` for a path inside an export's dictionary folder.
    static func dictionaryFolder(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "dictionaries", !parts[1].isEmpty else { return nil }
        return "dictionaries/\(parts[1])/"
    }

    private func get(_ url: URL) async throws(HachidoriError) -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw Self.error(error)
        }
        try Self.check(response)
        return data
    }

    private static func check(_ response: URLResponse) throws(HachidoriError) {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { return }
        switch status {
        case 200..<300: return
        case 404: throw .host(message: "Hachidori doesn't have that dictionary any more.", code: "404")
        default: throw .host(message: "Hachidori's dictionary service answered \(status).", code: String(status))
        }
    }

    private static func error(_ error: any Error) -> HachidoriError {
        (error as? URLError).map { _ in .notLinked } ?? .malformed(error.localizedDescription)
    }
}

/// Reports a download's progress (a task delegate gets the download callbacks too).
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
