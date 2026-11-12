import Core
import CoreTestSupport
import Foundation
import JellyfinKit
import Testing

@Suite struct JellyfinClientTests {
    let base = URL(string: "https://jellyfin.example.ts.net")!
    let identity = JellyfinClientIdentity(device: "Test iPhone", deviceId: "device-1", version: "0.1.0")

    func fixture(_ name: String) throws -> Data { try Fixture.data(name, in: .module) }

    func client(_ transport: StubTransport, token: String? = nil) -> JellyfinClient {
        JellyfinClient(baseURL: base, identity: identity, accessToken: token, http: HTTPClient(transport: transport))
    }

    @Test func publicInfoNeedsNoAuth() async throws {
        let transport = StubTransport(routes: ["/System/Info/Public": (200, try fixture("system-info-public.json"))])
        let check = try await client(transport).testConnection()
        #expect(check == JellyfinConnectionCheck(serverName: "Home", version: "12.3.0", user: nil))
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func testConnectionWithTokenVerifiesUser() async throws {
        let transport = StubTransport(routes: [
            "/System/Info/Public": (200, try fixture("system-info-public.json")),
            "/Users/Me": (200, try fixture("users-me.json")),
        ])
        let check = try await client(transport, token: "tok").testConnection()
        #expect(check.user == JellyfinUser(id: "00000000000000000000000000000000", name: "redacted"))
        let auth = try #require(transport.requests.last?.value(forHTTPHeaderField: "Authorization"))
        #expect(auth.hasSuffix(#", Token="tok""#))
    }

    @Test func authenticateSendsCredentialsAndDecodesToken() async throws {
        let transport = StubTransport(routes: ["/Users/AuthenticateByName": (200, try fixture("authenticate-by-name.json"))])
        let result = try await client(transport).authenticate(username: "me", password: "p&ss\"word")

        #expect(result.accessToken == "REDACTED-AccessToken")
        #expect(result.user.name == "redacted")

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(try request.jsonBody() as NSDictionary == ["Username": "me", "Pw": "p&ss\"word"] as NSDictionary)
        #expect(request.value(forHTTPHeaderField: "Authorization")
            == #"MediaBrowser Client="Miru", Device="Test%20iPhone", DeviceId="device-1", Version="0.1.0""#)
    }

    @Test func badCredentialsAreUnauthorized() async {
        let transport = StubTransport(routes: ["/Users/AuthenticateByName": (401, Data("Error processing request.".utf8))])
        await #expect(throws: ConnectionError.unauthorized) {
            try await client(transport).authenticate(username: "me", password: "wrong")
        }
    }

    @Test func expiredTokenIsUnauthorized() async throws {
        let transport = StubTransport(routes: [
            "/System/Info/Public": (200, try fixture("system-info-public.json")),
            "/Users/Me": (401, Data()),
        ])
        await #expect(throws: ConnectionError.unauthorized) { try await client(transport, token: "old").testConnection() }
    }

    @Test func nonJellyfinServerIsReported() async {
        let transport = StubTransport { _ in (404, Data()) }
        await #expect(throws: ConnectionError.notThisService("Expected a Jellyfin server.")) {
            try await client(transport).testConnection()
        }
    }

    @Test func signOutPostsLogout() async throws {
        let transport = StubTransport(routes: ["/Sessions/Logout": (204, Data())])
        try await client(transport, token: "tok").signOut()
        #expect(transport.requests.first?.httpMethod == "POST")
    }
}
