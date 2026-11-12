import Core
import Foundation

// Verified against Jellyfin 12.3.0 (2026-10-30):
// - `GET /System/Info/Public` is anonymous: ServerName, Version, ProductName, Id.
// - `POST /Users/AuthenticateByName` {Username, Pw} with the MediaBrowser
//   Authorization header returns AccessToken + User; bad credentials are 401.
// - `GET /Users/Me` with a token returns the user; a bad token is 401.
// - `POST /Sessions/Logout` revokes the token (204).

/// Identifies this app/device to Jellyfin. `deviceId` must be stable per install
/// or the server's device list fills up with duplicates.
public struct JellyfinClientIdentity: Equatable, Sendable {
    public var client: String
    public var device: String
    public var deviceId: String
    public var version: String

    public init(client: String = "Miru", device: String, deviceId: String, version: String) {
        self.client = client
        self.device = device
        self.deviceId = deviceId
        self.version = version
    }

    func authorizationHeader(token: String?) -> String {
        var fields = [
            ("Client", client), ("Device", device), ("DeviceId", deviceId), ("Version", version),
        ]
        if let token { fields.append(("Token", token)) }
        return "MediaBrowser " + fields.map { "\($0)=\"\(Self.escape($1))\"" }.joined(separator: ", ")
    }

    // Jellyfin URL-decodes header values; encoding keeps quotes, commas and non-ASCII safe.
    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "\",=&+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

public struct JellyfinPublicSystemInfo: Decodable, Equatable, Sendable {
    public var serverName: String
    public var version: String
    public var productName: String?
    public var id: String

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName", version = "Version", productName = "ProductName", id = "Id"
    }
}

public struct JellyfinUser: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name"
    }
}

public struct JellyfinAuthResult: Decodable, Equatable, Sendable {
    public var accessToken: String
    public var user: JellyfinUser
    public var serverId: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken", user = "User", serverId = "ServerId"
    }
}

public struct JellyfinConnectionCheck: Equatable, Sendable {
    public var serverName: String
    public var version: String
    /// Nil when no token was supplied (server reachable, not signed in).
    public var user: JellyfinUser?

    public init(serverName: String, version: String, user: JellyfinUser? = nil) {
        self.serverName = serverName
        self.version = version
        self.user = user
    }
}

public struct JellyfinClient: Sendable {
    public let baseURL: URL
    public let identity: JellyfinClientIdentity
    public let accessToken: String?
    /// Needed for browsing and playback; sign-in doesn't need it.
    public let userId: String?
    public let http: HTTPClient

    public init(
        baseURL: URL, identity: JellyfinClientIdentity, accessToken: String? = nil, userId: String? = nil,
        http: HTTPClient = HTTPClient()
    ) {
        self.baseURL = baseURL
        self.identity = identity
        self.accessToken = accessToken
        self.userId = userId
        self.http = http
    }

    func authorize(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue(identity.authorizationHeader(token: accessToken), forHTTPHeaderField: "Authorization")
        return request
    }

    public func publicSystemInfo() async throws(ConnectionError) -> JellyfinPublicSystemInfo {
        do {
            return try await http.decode(JellyfinPublicSystemInfo.self, from: .get(baseURL.appending(path: "System/Info/Public")))
        } catch .unexpectedResponse, .server(status: 404) {
            throw .notThisService("Expected a Jellyfin server.")
        }
    }

    public func authenticate(username: String, password: String) async throws(ConnectionError) -> JellyfinAuthResult {
        struct Body: Encodable {
            var Username: String
            var Pw: String
        }
        let request: URLRequest
        do {
            request = try .json("POST", baseURL.appending(path: "Users/AuthenticateByName"), body: Body(Username: username, Pw: password))
        } catch {
            throw .message(error.localizedDescription)
        }
        return try await http.decode(JellyfinAuthResult.self, from: authorize(request))
    }

    public func currentUser() async throws(ConnectionError) -> JellyfinUser {
        try await http.decode(JellyfinUser.self, from: authorize(.get(baseURL.appending(path: "Users/Me"))))
    }

    public func signOut() async throws(ConnectionError) {
        var request = URLRequest(url: baseURL.appending(path: "Sessions/Logout"))
        request.httpMethod = "POST"
        _ = try await http.send(authorize(request))
    }

    /// Reports server name and version; when a token is set, also verifies it.
    public func testConnection() async throws(ConnectionError) -> JellyfinConnectionCheck {
        let info = try await publicSystemInfo()
        let user = accessToken == nil ? nil : try await currentUser()
        return JellyfinConnectionCheck(serverName: info.serverName, version: info.version, user: user)
    }
}
