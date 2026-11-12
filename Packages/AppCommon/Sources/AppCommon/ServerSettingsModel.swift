import Anki
import Core
import Foundation
import Observation

public enum ConnectionStatus: Equatable {
    case idle
    case working
    case ok(String)
    case failed(String)
}

/// Shared persistence for the server forms: account row in SQLite, secret in Keychain.
@Observable
open class ServerSettingsModel {
    public let kind: ServerKind
    public let environment: CommonEnvironment
    public var urlText = ""
    public var status = ConnectionStatus.idle

    public init(kind: ServerKind, environment: CommonEnvironment) {
        self.kind = kind
        self.environment = environment
        if let account = try? environment.accounts.account(kind) {
            urlText = account.baseURL.absoluteString
            if let version = account.serverVersion {
                status = .ok("Last seen v\(version)")
            }
        }
    }

    public var isConfigured: Bool { environment.serverAccounts[kind] != nil }

    public func parsedURL() -> URL? {
        do {
            return try ServerURL.parse(urlText)
        } catch {
            status = .failed(error.localizedDescription)
            return nil
        }
    }

    public func secret(_ key: SecretKey) -> String {
        (try? environment.secrets.secret(for: key)) ?? ""
    }

    /// Runs `operation`, showing progress and turning thrown errors into a status message.
    public func perform(_ operation: () async throws -> String) async {
        status = .working
        do {
            status = .ok(try await operation())
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    public func saveAccount(_ account: ServerAccount, secrets: [SecretKey: String?] = [:]) throws {
        for (key, value) in secrets {
            try environment.secrets.setSecret(value, for: key)
        }
        try environment.accounts.save(account)
    }

    public func remove(secrets keys: [SecretKey]) {
        for key in keys { try? environment.secrets.setSecret(nil, for: key) }
        try? environment.accounts.delete(kind)
        urlText = ""
        status = .idle
    }
}

@Observable
public final class AnkiSettingsModel: ServerSettingsModel {
    var apiKey = ""

    init(environment: CommonEnvironment) {
        super.init(kind: .anki, environment: environment)
        apiKey = secret(.ankiAPIKey)
    }

    var canTest: Bool { !urlText.isEmpty && status != .working }

    func testAndSave() async {
        guard let url = parsedURL() else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        await perform {
            let check = try await AnkiConnectClient(baseURL: url, apiKey: key, http: environment.http).testConnection()
            try saveAccount(
                ServerAccount(kind: .anki, baseURL: url, serverName: "AnkiConnect",
                              serverVersion: String(check.version), lastCheckedAt: .now),
                secrets: [.ankiAPIKey: key.isEmpty ? nil : key]
            )
            Task { await environment.refreshMinedWords() }
            return "AnkiConnect v\(check.version) · \(check.deckCount) decks"
        }
    }

    func remove() {
        remove(secrets: [.ankiAPIKey])
        apiKey = ""
    }
}
