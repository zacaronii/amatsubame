@testable import AppCommon
import AudiobookshelfKit
import Core
import Foundation
import Testing

/// Answers every request with one status and body; keeps the requests' bodies.
final class KakuStatusStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var sent: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            Self.sent.append(data)
        } else if let body = request.httpBody {
            Self.sent.append(body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct KakuTranscriptSourceTests {
    @Test func whatMadeTheTranscript() {
        let day = Date(timeIntervalSince1970: 1_793_000_000)
        let date = day.formatted(date: .abbreviated, time: .omitted)
        #expect(KakuTranscriptSource.text(model: "anime-whisper", kaku: "1.7.0", made: day, saved: nil) == "anime-whisper · Kaku 1.7.0 · \(date)")
        #expect(KakuTranscriptSource.text(model: nil, kaku: nil, made: nil, saved: day) == "Saved \(date)", "a copy from before the model was kept")
    }

    func client() -> KakuClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KakuStatusStub.self]
        return KakuClient(baseURL: URL(string: "https://kaku.example")!, token: "t", http: HTTPClient(transport: URLSession(configuration: configuration)))
    }

    /// Kaku 1.6 queues it (202) even with a transcript; an older one answers that it's current.
    @Test func transcribeAgainAsksKakuToForceIt() async throws {
        KakuStatusStub.sent = []
        KakuStatusStub.status = 202
        KakuStatusStub.body = Data(#"{"itemId":"book","episodeId":"","state":"queued"}"#.utf8)
        let started = await KakuTranscriptSource.requestAgain(client(), itemId: "book", episodeId: "", whenDone: "Match Again when it's done.")
        #expect(started == "Kaku is transcribing it again. Match Again when it's done.")
        let body = try #require(KakuStatusStub.sent.first.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["itemId"] as? String == "book" && body["force"] as? Bool == true)

        KakuStatusStub.status = 200
        KakuStatusStub.body = Data(#"{"itemId":"book","episodeId":"","state":"done"}"#.utf8)
        #expect(await KakuTranscriptSource.requestAgain(client(), itemId: "book", episodeId: "", whenDone: "") == "Kaku needs to be 1.6 or newer to transcribe again.")

        KakuStatusStub.status = 500
        KakuStatusStub.body = Data()
        #expect(await KakuTranscriptSource.requestAgain(client(), itemId: "book", episodeId: "", whenDone: "").hasPrefix("Couldn't reach Kaku."))
    }
}
