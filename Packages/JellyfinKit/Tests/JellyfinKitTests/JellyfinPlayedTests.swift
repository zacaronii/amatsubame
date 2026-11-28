import Core
import CoreTestSupport
import Foundation
import Testing
@testable import JellyfinKit

/// Mark as Watched / Unwatched: POST or DELETE on the user's PlayedItems.
@Suite struct JellyfinPlayedTests {
    @Test func marksAnItemWatchedOrUnwatched() async throws {
        let transport = StubTransport { _ in (200, Data(#"{"Played": true}"#.utf8)) }
        let jellyfin = JellyfinClient(baseURL: URL(string: "https://jellyfin.example.ts.net")!,
                                      identity: JellyfinClientIdentity(device: "iPhone", deviceId: "d", version: "1"),
                                      accessToken: "tok", userId: "U1", http: HTTPClient(transport: transport))
        try await jellyfin.setPlayed(itemId: "item1", played: true)
        try await jellyfin.setPlayed(itemId: "item1", played: false)
        #expect(transport.requests.map(\.httpMethod) == ["POST", "DELETE"])
        #expect(transport.requests.allSatisfy { $0.url?.path() == "/Users/U1/PlayedItems/item1" })
        #expect(JellyfinPlayedPayload(itemId: "item1", played: true).coalesceKey == JellyfinPlayedPayload(itemId: "item1", played: false).coalesceKey,
                "the newest mark replaces one still waiting")
    }
}
