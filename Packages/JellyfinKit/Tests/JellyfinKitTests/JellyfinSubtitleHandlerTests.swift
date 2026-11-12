import Core
import CoreTestSupport
import Foundation
import JellyfinKit
import Synchronization
import Testing

final class Uploads: Sendable {
    let ids = Mutex<[String]>([])
}

@Suite struct JellyfinSubtitleHandlerTests {
    let base = URL(string: "https://jellyfin.example.ts.net")!
    let date = Date(timeIntervalSince1970: 1_793_400_000)
    let srt = Data("1\n00:00:01,000 --> 00:00:02,000\n日本語\n".utf8)

    func job(_ payload: Data? = nil) throws -> OutboxJob {
        OutboxJob(id: 1, kind: .jellyfinSubtitle, coalesceKey: nil,
                  payload: try payload ?? JSONEncoder().encode(JellyfinSubtitlePayload(itemId: "E", format: "srt")),
                  state: .inFlight, attempts: 0, lastError: nil, nextAttemptAt: date, createdAt: date, updatedAt: date)
    }

    func file() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "sub-\(UUID().uuidString).srt")
        try srt.write(to: url)
        return url
    }

    func handler(_ transport: StubTransport, uploaded: Uploads? = nil) -> JellyfinSubtitleHandler {
        let client = JellyfinClient(baseURL: base, identity: JellyfinClientIdentity(device: "d", deviceId: "i", version: "1"),
                                    accessToken: "tok", userId: "U", http: HTTPClient(transport: transport))
        return JellyfinSubtitleHandler(makeClient: { client }, didUpload: { id in uploaded?.ids.withLock { $0.append(id) } })
    }

    @Test func uploadsTheFileAsBase64() async throws {
        let transport = StubTransport { _ in (204, Data()) }
        let uploaded = Uploads()
        try await handler(transport, uploaded: uploaded).send(try job(), media: [(JellyfinSubtitleHandler.mediaField, try file())])
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url!.path() == "/Videos/E/Subtitles")
        let body = try request.jsonBody()
        #expect(body["Language"] as? String == "ja")
        #expect(body["Format"] as? String == "srt")
        #expect(body["IsForced"] as? Bool == false && body["IsHearingImpaired"] as? Bool == false)
        #expect((body["Data"] as? String).flatMap { Data(base64Encoded: $0) } == srt)
        #expect(Set(body.keys) == ["Language", "Format", "IsForced", "IsHearingImpaired", "Data"])
        #expect(uploaded.ids.withLock { $0 } == ["E"])
    }

    /// Replacing a separate server file: removed by its path first, then the new one goes up.
    @Test func replacingDeletesTheOldFileOnlyWhileItsPathMatches() async throws {
        @Sendable func item(_ streams: String) -> Data {
            Data(#"{"Id":"E","Name":"Ep","Type":"Episode","MediaSources":[{"Id":"M","MediaStreams":[\#(streams)]}]}"#.utf8)
        }
        let old = #"{"Index":3,"Type":"Subtitle","Language":"jpn","Codec":"subrip","IsExternal":true,"Path":"/m/ep.ja.srt"}"#
        let other = #"{"Index":2,"Type":"Subtitle","Language":"jpn","Codec":"subrip","IsExternal":true,"Path":"/m/ep.ja.hi.srt"}"#
        let payload = try JSONEncoder().encode(JellyfinSubtitlePayload(itemId: "E", format: "srt", replacesPath: "/m/ep.ja.srt"))
        let media = [(field: JellyfinSubtitleHandler.mediaField, url: try file())]

        let first = StubTransport { request in request.httpMethod == "GET" ? (200, item(other + "," + old)) : (204, Data()) }
        try await handler(first).send(try job(payload), media: media)
        #expect(first.requests.map { "\($0.httpMethod ?? "") \($0.url!.path())" }
                == ["GET /Items/E", "DELETE /Videos/E/Subtitles/3", "POST /Videos/E/Subtitles"])

        // A retry after the delete went through: the file's gone, so nothing else is deleted.
        let retry = StubTransport { request in request.httpMethod == "GET" ? (200, item(other)) : (204, Data()) }
        try await handler(retry).send(try job(payload), media: media)
        #expect(retry.requests.map { $0.httpMethod ?? "" } == ["GET", "POST"])
    }

    @Test func olderJobsWithoutReplacingDecode() throws {
        let decoded = try JSONDecoder().decode(JellyfinSubtitlePayload.self, from: Data(#"{"itemId":"E","format":"ass","language":"ja"}"#.utf8))
        #expect(decoded.replacesPath == nil && decoded.format == "ass")
    }

    @Test func failuresClassify() async throws {
        let media = [(field: JellyfinSubtitleHandler.mediaField, url: try file())]
        await #expect(throws: OutboxPermanentFailure.self, "no permission") {
            try await handler(StubTransport { _ in (403, Data()) }).send(try job(), media: media)
        }
        await #expect(throws: OutboxPermanentFailure.self, "bad request") {
            try await handler(StubTransport { _ in (400, Data()) }).send(try job(), media: media)
        }
        await #expect(throws: ConnectionError.server(status: 503), "server down: retry") {
            try await handler(StubTransport { _ in (503, Data()) }).send(try job(), media: media)
        }
        await #expect(throws: OutboxPermanentFailure.self, "file missing") {
            try await handler(StubTransport { _ in (204, Data()) }).send(try job(), media: [])
        }
    }
}
