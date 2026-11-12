import Anki
import Core
import CoreTestSupport
import Foundation
import Testing

@Suite struct AnkiConnectClientTests {
    let base = URL(string: "http://anki.example.ts.net:8765")!

    func fixture(_ name: String) throws -> Data { try Fixture.data(name, in: .module) }

    /// Routes on the JSON `action` since AnkiConnect uses a single endpoint.
    func transport(_ actions: [String: Data]) -> StubTransport {
        StubTransport { request in
            let action = try request.jsonBody()["action"] as? String ?? ""
            return actions[action].map { (200, $0) } ?? (200, Data(#"{"result":null,"error":"Unsupported action: \#(action)"}"#.utf8))
        }
    }

    @Test func testConnectionReportsVersionAndDecks() async throws {
        let stub = transport(["version": try fixture("version.json"), "deckNames": try fixture("deck-names.json")])
        let check = try await AnkiConnectClient(baseURL: base, http: HTTPClient(transport: stub)).testConnection()
        #expect(check == AnkiConnectCheck(version: 6, deckCount: 5))
    }

    @Test func sendsJSONEnvelopeWithoutKeyWhenUnset() async throws {
        let stub = transport(["version": try fixture("version.json")])
        _ = try await AnkiConnectClient(baseURL: base, apiKey: "", http: HTTPClient(transport: stub)).version()

        let request = try #require(stub.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try request.jsonBody() as NSDictionary == ["action": "version", "version": 6] as NSDictionary)
    }

    @Test func sendsKeyWhenSet() async throws {
        let stub = transport(["version": try fixture("version.json")])
        _ = try await AnkiConnectClient(baseURL: base, apiKey: "k", http: HTTPClient(transport: stub)).version()
        #expect(try stub.requests[0].jsonBody()["key"] as? String == "k")
    }

    @Test func decodesDeckNames() async throws {
        let stub = transport(["deckNames": try fixture("deck-names.json")])
        let decks = try await AnkiConnectClient(baseURL: base, http: HTTPClient(transport: stub)).deckNames()
        #expect(decks.contains("Japanese::Mining"))
    }

    @Test func actionErrorsSurfaceAsMessages() async throws {
        let stub = transport(["noSuchAction": try fixture("error-unsupported-action.json")])
        await #expect(throws: ConnectionError.message("AnkiConnect: Unsupported action: noSuchAction")) {
            let _: Int = try await AnkiConnectClient(baseURL: base, http: HTTPClient(transport: stub)).invoke("noSuchAction")
        }
    }

    @Test func invalidKeyIsUnauthorized() async {
        let stub = StubTransport { _ in (200, Data(#"{"result":null,"error":"valid api key must be provided"}"#.utf8)) }
        await #expect(throws: ConnectionError.unauthorized) {
            try await AnkiConnectClient(baseURL: base, apiKey: "wrong", http: HTTPClient(transport: stub)).version()
        }
    }

    @Test func nonAnkiServerIsReported() async {
        let stub = StubTransport { _ in (405, Data(#"{"detail":"Method Not Allowed"}"#.utf8)) }
        await #expect(throws: ConnectionError.notThisService("Expected an AnkiConnect server.")) {
            try await AnkiConnectClient(baseURL: base, http: HTTPClient(transport: stub)).version()
        }
    }
}
