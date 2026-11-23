import Foundation
import Synchronization
import Testing
@testable import Yomu

/// A slow audio server: the body in chunks, stopping when the transfer is cancelled.
final class SlowAudioProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex(0)
    static let status = Mutex(200)
    static let chunks = Mutex(4)
    private let stopped = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        let chunks = Self.chunks.withLock { $0 }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status.withLock { $0 }, httpVersion: nil,
                                       headerFields: ["Content-Length": String(chunks * 1000)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async { [self] in
            for _ in 0..<chunks {
                Thread.sleep(forTimeInterval: 0.15)
                if stopped.withLock({ $0 }) { return }
                client?.urlProtocol(self, didLoad: Data(repeating: 7, count: 1000))
            }
            if !stopped.withLock({ $0 }) { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() { stopped.withLock { $0 = true } }
}

@MainActor @Suite(.serialized) struct ReadAlongDownloadsTests {
    func make(chunks: Int = 4, status: Int = 200) -> (ReadAlongDownloads, URL) {
        SlowAudioProtocol.requests.withLock { $0 = 0 }
        SlowAudioProtocol.chunks.withLock { $0 = chunks }
        SlowAudioProtocol.status.withLock { $0 = status }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowAudioProtocol.self]
        let folder = URL.temporaryDirectory.appending(path: "ReadAlongAudio-\(UUID().uuidString)")
        let downloads = ReadAlongDownloads(folder: folder, session: URLSession(configuration: configuration)) { _ in
            (URLRequest(url: URL(string: "https://abs.example/audio")!), "m4b")
        }
        return (downloads, folder)
    }

    func waitUntilDone(_ downloads: ReadAlongDownloads, _ itemId: String) async {
        for _ in 0..<100 where downloads.isRunning(itemId) { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func aDownloadLandsOnceAndASecondTapReusesIt() async {
        let (downloads, _) = make()
        downloads.start(itemId: "book")
        downloads.start(itemId: "book")
        #expect(downloads.isRunning("book"))
        var seen = 0.0
        for _ in 0..<100 where downloads.isRunning("book") {
            if let fraction = downloads.running["book"] ?? nil { seen = max(seen, fraction) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(seen > 0, "progress from the transfer")
        #expect(SlowAudioProtocol.requests.withLock { $0 } == 1, "one transfer")
        #expect(downloads.localFile(itemId: "book")?.pathExtension == "m4b")
        #expect(downloads.bytes == 4000 && downloads.fileCount == 1)
        downloads.start(itemId: "book")
        #expect(!downloads.isRunning("book"), "already here: nothing starts")
    }

    @Test func cancellingLeavesNothingBehind() async {
        let (downloads, folder) = make(chunks: 20)
        downloads.start(itemId: "book")
        try? await Task.sleep(for: .milliseconds(400))
        await downloads.cancel(itemId: "book")
        #expect(!downloads.isRunning("book"))
        #expect(downloads.localFile(itemId: "book") == nil)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder.path())) ?? []).isEmpty)
        #expect(downloads.results["book"] == nil, "a cancel isn't a failure")
    }

    @Test func deletingStopsARunningDownloadFirst() async {
        let (downloads, _) = make(chunks: 20)
        downloads.start(itemId: "book")
        try? await Task.sleep(for: .milliseconds(300))
        await downloads.delete(itemId: "book")
        try? await Task.sleep(for: .milliseconds(500))
        #expect(downloads.localFile(itemId: "book") == nil, "nothing written after the delete")
        #expect(downloads.fileCount == 0)
    }

    @Test func removeAllAndAFailureLeaveNoFile() async {
        let (downloads, _) = make()
        downloads.start(itemId: "a")
        await waitUntilDone(downloads, "a")
        await downloads.deleteAll()
        #expect(downloads.fileCount == 0 && downloads.bytes == 0)
        let (failing, _) = make(status: 404)
        failing.start(itemId: "b")
        await waitUntilDone(failing, "b")
        #expect(failing.localFile(itemId: "b") == nil)
        #expect(failing.results["b"]?.contains("Couldn") == true)
    }

    @Test func unpairingKeepsAudioAnotherVolumeReadsAlongWith() {
        #expect(ReadAlongDownloads.deletesAudio(unpairing: 1, pairs: [1]))
        #expect(!ReadAlongDownloads.deletesAudio(unpairing: 1, pairs: [1, 2]))
    }

    @Test func theRowsLineFollowsTheDownload() {
        let downloading = "Downloading the audio\u{2026} Keep Yomu open."
        #expect(ReadAlongDownloads.caption(running: true, result: "Audio downloaded (1 MB).", rowMessage: "old") == downloading, "running wins")
        #expect(ReadAlongDownloads.caption(running: false, result: "Audio downloaded (1 MB).", rowMessage: nil) == "Audio downloaded (1 MB).",
                "the result once it has ended")
        #expect(ReadAlongDownloads.caption(running: false, result: "Couldn\u{2019}t download the audio: offline", rowMessage: "Set up Kaku")
                == "Couldn\u{2019}t download the audio: offline", "a failure isn't hidden by an older message")
        #expect(ReadAlongDownloads.caption(running: false, result: nil, rowMessage: "Set up Kaku") == "Set up Kaku")
    }

    @Test func unpairAsksOnlyWhenItWouldDeleteDownloadedAudio() {
        #expect(ReadAlongDownloads.asksBeforeUnpairing(1, hasAudio: true, pairs: [1]))
        #expect(!ReadAlongDownloads.asksBeforeUnpairing(1, hasAudio: false, pairs: [1]), "nothing downloaded: no question")
        #expect(!ReadAlongDownloads.asksBeforeUnpairing(1, hasAudio: true, pairs: [1, 2]), "another volume keeps the audio")
    }
}
