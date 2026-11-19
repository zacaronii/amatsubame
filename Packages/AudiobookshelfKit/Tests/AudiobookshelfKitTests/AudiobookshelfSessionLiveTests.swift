import AudiobookshelfKit
import Core
import Foundation
import Testing

/// Sends a listening session through the client to a real server, as the apps do. Runs only
/// with `LIVE_ABS_URL`, `LIVE_ABS_USER` and `LIVE_ABS_PASSWORD` (a test account) set; prints
/// the session's id so it can be deleted afterwards (that needs an admin).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIVE_ABS_URL"] != nil))
struct AudiobookshelfSessionLiveTests {
    @Test func sendsASession() async throws {
        let env = ProcessInfo.processInfo.environment
        let base = try #require(URL(string: env["LIVE_ABS_URL"] ?? ""))
        let secrets = InMemorySecretStore()
        let login = try await AudiobookshelfClient(baseURL: base)
            .login(username: env["LIVE_ABS_USER"] ?? "", password: env["LIVE_ABS_PASSWORD"] ?? "")
        try secrets.setSecret(login.accessToken, for: .audiobookshelfToken)
        let client = AudiobookshelfClient(baseURL: base, tokens: AudiobookshelfTokens(secrets: secrets))

        let library = try #require(await client.libraries().first { $0.mediaType == .podcast })
        let episode = try #require(await client.recentEpisodes(libraryId: library.id, limit: 1).first)
        let device = AudiobookshelfDeviceInfo(deviceId: "livecheck-kiku", clientName: "Kiku", clientVersion: "0", model: "test")
        let end = Date()
        let session = AudiobookshelfSessionPayload(
            id: UUID().uuidString.lowercased(), libraryItemId: episode.libraryItemId, episodeId: episode.id,
            mediaType: "podcast", duration: 0, deviceInfo: device, startTime: 0, currentTime: 0,
            timeListening: 30, startedAt: end.addingTimeInterval(-30), updatedAt: end.addingTimeInterval(-86_400 * 365))
        print("live session id:", session.id)
        let refusal = try await client.syncSession(session)
        #expect(refusal == nil)
    }
}
