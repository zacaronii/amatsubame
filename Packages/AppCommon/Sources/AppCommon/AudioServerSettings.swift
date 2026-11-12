import AudiobookshelfKit
import Core
import Foundation
import Observation

@Observable
public final class AudiobookshelfSettingsModel: ServerSettingsModel {
    public enum Method: Hashable {
        case password, apiKey
    }

    public var method = Method.password
    public var username = ""
    public var password = ""
    public var apiKey = ""
    @ObservationIgnored private let tokens: AudiobookshelfTokens

    public init(environment: CommonEnvironment, tokens: AudiobookshelfTokens) {
        self.tokens = tokens
        super.init(kind: .audiobookshelf, environment: environment)
        username = (try? environment.accounts.account(.audiobookshelf))?.username ?? ""
    }

    public var isSignedIn: Bool { environment.serverAccounts[.audiobookshelf] != nil && !secret(.audiobookshelfToken).isEmpty }
    public var canSignIn: Bool {
        guard !urlText.isEmpty, status != .working else { return false }
        return method == .password ? !username.isEmpty : !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func client(_ url: URL) -> AudiobookshelfClient {
        AudiobookshelfClient(baseURL: url, tokens: tokens, http: environment.http)
    }

    public func testConnection() async {
        guard let url = parsedURL() else { return }
        await perform {
            let client = client(url)
            let status = try await client.status()
            guard isSignedIn else { return "Audiobookshelf \(status.serverVersion) · not signed in" }
            let user = try await client.me()
            if var account = try environment.accounts.account(.audiobookshelf), account.baseURL == url {
                account.serverVersion = status.serverVersion
                account.lastCheckedAt = .now
                try environment.accounts.save(account)
            }
            return "Audiobookshelf \(status.serverVersion) · \(user.username)"
        }
    }

    /// Signs in with a password (keeping only the tokens) or checks and keeps a pasted API key.
    public func signIn() async {
        guard let url = parsedURL() else { return }
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pw = password
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = method
        await perform {
            let status = try await AudiobookshelfClient(baseURL: url, http: environment.http).status()
            let user: AudiobookshelfUser
            let secrets: [SecretKey: String?]
            switch method {
            case .password:
                user = try await AudiobookshelfClient(baseURL: url, http: environment.http).login(username: name, password: pw)
                guard let access = user.accessToken else { throw ConnectionError.unexpectedResponse("No access token in the sign-in answer.") }
                secrets = [.audiobookshelfToken: access, .audiobookshelfRefreshToken: user.refreshToken]
            case .apiKey:
                // Saved first so the client can use it; removed again if the check fails.
                try environment.secrets.setSecret(key, for: .audiobookshelfToken)
                try environment.secrets.setSecret(nil, for: .audiobookshelfRefreshToken)
                do {
                    user = try await client(url).me()
                } catch {
                    try? environment.secrets.setSecret(nil, for: .audiobookshelfToken)
                    throw error
                }
                secrets = [.audiobookshelfToken: key, .audiobookshelfRefreshToken: nil]
            }
            try saveAccount(
                ServerAccount(kind: .audiobookshelf, baseURL: url, username: user.username, userId: user.id,
                              serverName: "Audiobookshelf", serverVersion: status.serverVersion, lastCheckedAt: .now),
                secrets: secrets
            )
            password = ""
            apiKey = ""
            return "Audiobookshelf \(status.serverVersion) · \(user.username)"
        }
    }

    public func signOut() {
        remove(secrets: [.audiobookshelfToken, .audiobookshelfRefreshToken])
        password = ""
        apiKey = ""
    }
}

@Observable
public final class KakuSettingsModel: ServerSettingsModel {
    public var token = ""

    public init(environment: CommonEnvironment) {
        super.init(kind: .kaku, environment: environment)
        token = secret(.kakuAPIToken)
    }

    public var canTest: Bool { !urlText.isEmpty && !token.isEmpty && status != .working }

    public func testAndSave() async {
        guard let url = parsedURL() else { return }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        await perform {
            let client = KakuClient(baseURL: url, token: token, http: environment.http)
            let health = try await client.health()
            try await client.authorizedCheck()
            try saveAccount(
                ServerAccount(kind: .kaku, baseURL: url, serverName: "Kaku", serverVersion: health.version, lastCheckedAt: .now),
                secrets: [.kakuAPIToken: token]
            )
            let done = health.jobs?["done"].map { " · \($0) transcripts" } ?? ""
            return "Kaku \(health.version)\(done)"
        }
    }

    public func remove() {
        remove(secrets: [.kakuAPIToken])
        token = ""
    }
}

/// Audiobookshelf and Kaku clients from the saved accounts (Kiku, and Yomu's read-along).
public enum AudioServers {
    /// Reads the saved account each time, so Settings changes apply immediately. Nil until signed in.
    public static func audiobookshelfClientFactory(
        accounts: AccountStore, tokens: AudiobookshelfTokens, http: HTTPClient
    ) -> @Sendable () throws -> AudiobookshelfClient? {
        {
            guard let account = try accounts.account(.audiobookshelf) else { return nil }
            return AudiobookshelfClient(baseURL: account.baseURL, tokens: tokens, http: http)
        }
    }

    /// Nil until Kaku's URL and token are saved in Settings.
    public static func kakuClient(_ common: CommonEnvironment) -> KakuClient? {
        guard let account = try? common.accounts.account(.kaku),
              let token = try? common.secrets.secret(for: .kakuAPIToken), !token.isEmpty else { return nil }
        return KakuClient(baseURL: account.baseURL, token: token, http: common.http)
    }
}
