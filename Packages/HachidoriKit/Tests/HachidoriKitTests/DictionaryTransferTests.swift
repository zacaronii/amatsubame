import Foundation
@testable import HachidoriKit
import Synchronization
import Testing
import ZIPFoundation

/// Serves canned responses by URL (the test's own session only).
final class ExportStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.responses[request.url!.absoluteString]
        let response = HTTPURLResponse(url: request.url!, statusCode: data == nil ? 404 : 200, httpVersion: nil,
                                       headerFields: ["Content-Length": String(data?.count ?? 0)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExportStub.self]
        return URLSession(configuration: configuration)
    }
}

func temporaryFolder() -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "hd-transfer-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A host export: `hachidori-backup.json` (with a secret that must never be unpacked) and the
/// dictionary folder, plus an entry that tries to climb out of it.
func makeExport(at url: URL) throws {
    let archive = try Archive(url: url, accessMode: .create)
    let entries: [(String, Data)] = [
        ("hachidori-backup.json", Data(#"{"snapshot":{"options":{"anki":{"apiKey":"secret"}}}}"#.utf8)),
        ("dictionaries/0/.hoshidicts_6", Data()),
        ("dictionaries/0/index.json", Data(#"{"title":"Test","revision":"2"}"#.utf8)),
        ("dictionaries/0/media/a.bin", Data([1, 2, 3])),
        ("dictionaries/0/../escaped.txt", Data("no".utf8)),
    ]
    for (path, data) in entries {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }
}

@Suite struct DictionaryExportTests {
    @Test func theAPIIsOnTheLinksHost() {
        #expect(HostDictionaryExports.apiURL(forLink: URL(string: "ws://host.example:8771/link")!)?.absoluteString
            == "http://host.example:19633")
        #expect(HostDictionaryExports.apiURL(forLink: URL(string: "wss://host.example/link")!)?.absoluteString
            == "https://host.example:19633")
    }

    @Test func onlyTheDictionaryFolderIsUnpacked() throws {
        let work = temporaryFolder()
        let zip = work.appending(path: "export.zip")
        try makeExport(at: zip)
        let folder = work.appending(path: "out/dictionary")
        try HostDictionaryExports.unpack(zip, into: folder)
        let fileManager = FileManager.default
        #expect(try Data(contentsOf: folder.appending(path: ".hoshidicts_6")).isEmpty, "the format marker stays empty")
        #expect(fileManager.fileExists(atPath: folder.appending(path: "index.json").path()))
        #expect(try Data(contentsOf: folder.appending(path: "media/a.bin")) == Data([1, 2, 3]))
        let everything = try fileManager.subpathsOfDirectory(atPath: work.path())
        #expect(!everything.contains { $0.hasSuffix("hachidori-backup.json") }, "the host's settings (and Anki key) stay packed")
        #expect(!everything.contains { $0.hasSuffix("escaped.txt") })
    }

    @Test func aDownloadWithoutAFolderIsRefused() throws {
        let work = temporaryFolder()
        let zip = work.appending(path: "export.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        try archive.addEntry(with: "hachidori-backup.json", type: .file, uncompressedSize: 2, compressionMethod: .none) { (_: Int64, _: Int) in Data("{}".utf8) }
        #expect(throws: HachidoriError.malformed("the dictionary download has no dictionary folder")) {
            try HostDictionaryExports.unpack(zip, into: work.appending(path: "out"))
        }
    }

    @Test func listsAndDownloads() async throws {
        let base = URL(string: "http://stub.example:19633")!
        ExportStub.responses = [
            "http://stub.example:19633/dictionaries": Data(#"""
            {"type":"hd_api_dictionaries_result","ok":true,"dictionaries":[
             {"id":"abc","title":"Jitendex.org [2026-10-03]","revision":"2026.10.03.0","size":null,"fileName":"Jitendex.org [2026-10-03].hachidori.zip"}]}
            """#.utf8),
            "http://stub.example:19633/dictionaries/abc": Data("zip bytes".utf8),
        ]
        let exports = HostDictionaryExports(baseURL: base, session: ExportStub.session)
        #expect(try await exports.list() == [.init(id: "abc", title: "Jitendex.org [2026-10-03]", revision: "2026.10.03.0",
                                                  fileName: "Jitendex.org [2026-10-03].hachidori.zip")])
        let file = temporaryFolder().appending(path: "abc.zip")
        try await exports.download("abc", to: file)
        #expect(try Data(contentsOf: file) == Data("zip bytes".utf8))
        await #expect(throws: HachidoriError.host(message: "Hachidori doesn't have that dictionary any more.", code: "404")) {
            try await exports.download("gone", to: file)
        }
    }
}

@Suite struct SendDictionaryTests {
    func link(_ host: FakeHost) -> HachidoriLink {
        LinkTests().link(host)
    }

    @Test func sendsInOrderThenCommits() async throws {
        let host = FakeHost(hello: try fixture("hello"))
        let messages = Mutex<[JSONValue]>([])
        host.respond { message in
            messages.withLock { $0.append(message) }
            switch message["type"]?.string {
            case "hd_import_begin": return ["ok": true, "token": "t1", "chunkBytes": 4]
            case "hd_import_chunk": return ["ok": true, "received": 0]
            case "hd_import_commit": return ["ok": true, "imported": "Test"]
            default: return nil
            }
        }
        let zip = temporaryFolder().appending(path: "Test Dictionary.zip")
        try Data("0123456789".utf8).write(to: zip)
        let link = link(host)
        await link.start()
        let fractions = Mutex<[Double]>([])
        let reply = try await link.sendDictionary(zip, replace: true) { fraction in fractions.withLock { $0.append(fraction) } }
        #expect(reply["imported"] == "Test")

        let sent = messages.withLock { $0 }
        #expect(sent.map { $0["type"]?.string } == ["hd_import_begin", "hd_import_chunk", "hd_import_chunk", "hd_import_chunk", "hd_import_commit"])
        #expect(sent.allSatisfy { $0["target"] == "hachidori-linked-import" })
        #expect(sent[0]["fileName"] == "Test Dictionary.zip" && sent[0]["size"] == 10 && sent[0]["replace"] == true)
        #expect(sent[1...3].map { $0["offset"]?.int } == [0, 4, 8])
        let joined = sent[1...3].compactMap { $0["data"]?.string }.compactMap { Data(base64Encoded: $0) }.reduce(Data(), +)
        #expect(joined == Data("0123456789".utf8))
        #expect(sent.last?["token"] == "t1")
        #expect(fractions.withLock { $0 } == [0.4, 0.8, 1])
        await link.stop()
    }

    @Test func aRefusedChunkAbortsTheUpload() async throws {
        let host = FakeHost(hello: try fixture("hello"))
        let types = Mutex<[String]>([])
        host.respond { message in
            types.withLock { $0.append(message["type"]?.string ?? "") }
            switch message["type"]?.string {
            case "hd_import_begin": return ["ok": true, "token": "t1", "chunkBytes": 4]
            case "hd_import_chunk": return ["ok": false, "error": "The dictionary upload expected byte 4, not 0."]
            default: return ["ok": true]
            }
        }
        let zip = temporaryFolder().appending(path: "Test.zip")
        try Data("0123456789".utf8).write(to: zip)
        let link = link(host)
        await link.start()
        await #expect(throws: HachidoriError.self) { try await link.sendDictionary(zip, replace: false) }
        await waitUntil { types.withLock { $0.last } == "hd_import_abort" }
        #expect(types.withLock { $0 } == ["hd_import_begin", "hd_import_chunk", "hd_import_abort"])
        await link.stop()
    }

    @Test func aHostWithoutLinkedImportIsTold() async throws {
        let hello = try fixture("hello").replacingOccurrences(of: "\"linked-import-v1\"", with: "\"other-v1\"")
        let host = FakeHost(hello: hello)
        let zip = temporaryFolder().appending(path: "Test.zip")
        try Data("0123".utf8).write(to: zip)
        let link = link(host)
        await link.start()
        await #expect(throws: HachidoriError.host(message: "This Hachidori doesn't accept dictionaries from other apps. Update it and try again.", code: nil)) {
            try await link.sendDictionary(zip, replace: false)
        }
        await link.stop()
    }

    func waitUntil(_ condition: @Sendable () async -> Bool) async {
        for _ in 0..<200 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
