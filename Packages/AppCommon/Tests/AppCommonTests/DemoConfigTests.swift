import AppCommon
import Foundation
import Testing

/// The published demo details (made-up values: the real ones are only ever fetched).
@Suite struct DemoConfigTests {
    static let sample = Data("""
    {"version": 1,
     "kavita": {"url": "https://kavita.example.com", "apiKey": "made-up-key"},
     "jellyfin": {"url": "https://jellyfin.example.com", "user": "visitor", "password": "made-up"},
     "audiobookshelf": {"url": "https://abs.example.com", "user": "visitor", "password": "made-up"},
     "message": "Resets every night."}
    """.utf8)

    @Test func readsEachServer() throws {
        let config = try DemoConfig.parse(Self.sample)
        #expect(config.kavita?.url == URL(string: "https://kavita.example.com"))
        #expect(config.kavita?.apiKey == "made-up-key")
        #expect(config.jellyfin?.user == "visitor" && config.audiobookshelf?.password == "made-up")
        #expect(config.message == "Resets every night.")
    }

    /// A server left out is just not offered; an unknown field is ignored.
    @Test func serversAreOptional() throws {
        let config = try DemoConfig.parse(Data(#"{"version": 1, "kavita": {"url": "https://kavita.example.com", "apiKey": "k"}, "extra": true}"#.utf8))
        #expect(config.kavita != nil && config.jellyfin == nil && config.audiobookshelf == nil)
    }

    @Test func aNewerShapeAsksForAnUpdate() {
        #expect(throws: DemoConfig.Failure.newerVersion) { try DemoConfig.parse(Data(#"{"version": 2}"#.utf8)) }
    }

    @Test func anythingElseIsUnavailable() {
        #expect(throws: DemoConfig.Failure.unavailable) { try DemoConfig.parse(Data("<html>Not found</html>".utf8)) }
        #expect(throws: DemoConfig.Failure.unavailable) { try DemoConfig.parse(Data(#"{"version": 1, "kavita": {"url": 3}}"#.utf8)) }
    }
}
