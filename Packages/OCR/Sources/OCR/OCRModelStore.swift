import CoreML
import CryptoKit
import Foundation
import Observation

/// Downloads, verifies and compiles the OCR models (nemu-ocr-coreml, Apache-2.0)
/// into Application Support. Files come from a pinned Hugging Face commit and must
/// match the SHA-256 hashes below.
@MainActor @Observable
public final class OCRModelStore {
    public enum State: Equatable, Sendable {
        case notInstalled
        case downloading(fraction: Double)
        case compiling
        case installed
        case failed(String)
    }

    nonisolated public static let revision = "691285cc539f4662f785540efcc9a62d51a1095c"
    /// Stored with cached OCR results; a new model version re-runs OCR.
    nonisolated public static let modelVersion = "nemu-ocr-691285c"
    nonisolated static let baseURL = URL(string: "https://huggingface.co/nemu-pm/nemu-ocr-coreml/resolve/\(revision)/")!

    struct ModelFile: Sendable {
        var path: String
        var bytes: Int
        var sha256: String
    }

    nonisolated static let packages = ["ogkalu-ctbd-v4s-fp16", "mangaocr-encoder-int8", "mangaocr-decoder-int8"]

    nonisolated static let files: [ModelFile] = [
        ModelFile(path: "vocab.txt", bytes: 24072, sha256: "344fbb6b8bf18c57839e924e2c9365434697e0227fac00b88bb4899b78aa594d"),
        ModelFile(path: "ogkalu-ctbd-v4s-fp16.mlpackage/Manifest.json", bytes: 617, sha256: "ea71993f1816afe2eaa6e1afde984f3da6a84709172b67df561a388d1a990b65"),
        ModelFile(path: "ogkalu-ctbd-v4s-fp16.mlpackage/Data/com.apple.CoreML/model.mlmodel", bytes: 348572, sha256: "8dff4f6396bdcb78fbcb7a4eca8a5727eeff0c5b724fb8eb2948afc19791d2bb"),
        ModelFile(path: "ogkalu-ctbd-v4s-fp16.mlpackage/Data/com.apple.CoreML/weights/weight.bin", bytes: 20650688, sha256: "d44f9bc16335f139df319b7ca109dc25404174833cd6441590e720c87136b537"),
        ModelFile(path: "mangaocr-encoder-int8.mlpackage/Manifest.json", bytes: 617, sha256: "7746f6eb8b766e8cdd270a70a3e4e7f953600f7662f650c9195aa67121f8ae6c"),
        ModelFile(path: "mangaocr-encoder-int8.mlpackage/Data/com.apple.CoreML/model.mlmodel", bytes: 150209, sha256: "4760438fc8718b236395d2e1b71bc9c93e8d58c620e1666911415571c0593a4c"),
        ModelFile(path: "mangaocr-encoder-int8.mlpackage/Data/com.apple.CoreML/weights/weight.bin", bytes: 86110336, sha256: "407a6a3ff79c42eab4b29f10cf90450c1790d8b0dff5a41904b21dce1c30889f"),
        ModelFile(path: "mangaocr-decoder-int8.mlpackage/Manifest.json", bytes: 617, sha256: "56b97b180b9d0b1b0d34db0c97bdf2c322160540070bf7f18bee3e87a0f45e46"),
        ModelFile(path: "mangaocr-decoder-int8.mlpackage/Data/com.apple.CoreML/model.mlmodel", bytes: 83482, sha256: "41d730617c622d30fa76b0718abf2eb69c6c0d22be7b8f2e073f886e7d2c3217"),
        ModelFile(path: "mangaocr-decoder-int8.mlpackage/Data/com.apple.CoreML/weights/weight.bin", bytes: 24728960, sha256: "fe9c5a2a3737cf6939fbfb0ed1929df52f486dc2609dfc4541c4d4c9df826eb0"),
    ]

    nonisolated public static var totalBytes: Int { files.reduce(0) { $0 + $1.bytes } }

    public private(set) var state = State.notInstalled
    public let directory: URL
    private let session: URLSession
    private var task: Task<Void, Never>?

    public init(directory: URL, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
        state = Self.isInstalled(in: directory) ? .installed : .notInstalled
    }

    var downloads: URL { directory.appending(path: "download", directoryHint: .isDirectory) }
    var compiled: URL { directory.appending(path: "compiled", directoryHint: .isDirectory) }

    nonisolated static func isInstalled(in directory: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: directory.appending(path: "compiled/vocab.txt").path(percentEncoded: false))
            && packages.allSatisfy {
                manager.fileExists(atPath: directory.appending(path: "compiled/\($0).mlmodelc").path(percentEncoded: false))
            }
    }

    /// Where the compiled models live once installed.
    public var modelDirectory: URL? { state == .installed ? compiled : nil }

    public func install() {
        guard task == nil, state != .installed else { return }
        task = Task {
            defer { task = nil }
            do {
                try await download()
                state = .compiling
                try await compile()
                try? FileManager.default.removeItem(at: downloads)
                state = .installed
            } catch is CancellationError {
                state = .notInstalled
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    public func cancel() {
        task?.cancel()
    }

    public func delete() {
        task?.cancel()
        try? FileManager.default.removeItem(at: directory)
        state = .notInstalled
    }

    /// Fetches each file unless an already-downloaded copy matches its hash.
    private func download() async throws {
        let manager = FileManager.default
        var done = 0
        state = .downloading(fraction: 0)
        for file in Self.files {
            try Task.checkCancellation()
            let destination = downloads.appending(path: file.path)
            if let existing = try? Data(contentsOf: destination), Self.sha256(existing) == file.sha256 {
                done += file.bytes
                continue
            }
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = done
            let (temporary, response) = try await session.download(from: Self.baseURL.appending(path: file.path), delegate: ProgressDelegate { [weak self] written in
                Task { @MainActor in self?.state = .downloading(fraction: Double(base + Int(written)) / Double(Self.totalBytes)) }
            })
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw OCRError.downloadFailed(file.path) }
            let hash = try Self.sha256(of: temporary)
            guard hash == file.sha256 else {
                try? manager.removeItem(at: temporary)
                throw OCRError.checksumMismatch(file.path)
            }
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: temporary, to: destination)
            done += file.bytes
            state = .downloading(fraction: Double(done) / Double(Self.totalBytes))
        }
    }

    private func compile() async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: compiled, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        for package in Self.packages {
            let output = try await MLModel.compileModel(at: downloads.appending(path: "\(package).mlpackage"))
            let destination = compiled.appending(path: "\(package).mlmodelc")
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: output, to: destination)
        }
        let vocab = compiled.appending(path: "vocab.txt")
        try? manager.removeItem(at: vocab)
        try manager.copyItem(at: downloads.appending(path: "vocab.txt"), to: vocab)
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let onProgress: @Sendable (Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

public enum OCRError: Error, Equatable, LocalizedError {
    case downloadFailed(String)
    case checksumMismatch(String)
    case modelsNotInstalled
    case unexpectedModelOutput(String)
    case imageConversionFailed

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let file): "Couldn't download \(file)."
        case .checksumMismatch(let file): "\(file) didn't match its expected checksum. Try again."
        case .modelsNotInstalled: "Download the OCR models in Settings → OCR first."
        case .unexpectedModelOutput(let detail): "The OCR model returned something unexpected (\(detail))."
        case .imageConversionFailed: "The page image couldn't be prepared for OCR."
        }
    }
}
