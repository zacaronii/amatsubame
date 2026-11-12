import AppCommon
import Core
import Foundation
import JellyfinKit
import Observation
#if canImport(UIKit)
import UIKit
#endif

@Observable
final class JellyfinSettingsModel: ServerSettingsModel {
    var username = ""
    var password = ""

    init(environment: CommonEnvironment) {
        super.init(kind: .jellyfin, environment: environment)
        username = (try? environment.accounts.account(.jellyfin))?.username ?? ""
    }

    var isSignedIn: Bool { environment.serverAccounts[.jellyfin]?.userId != nil && !secret(.jellyfinAccessToken).isEmpty }
    var canSignIn: Bool { !urlText.isEmpty && !username.isEmpty && status != .working }

    private func client(_ url: URL, token: String?) -> JellyfinClient {
        JellyfinClient(baseURL: url, identity: JellyfinIdentity.make(secrets: environment.secrets), accessToken: token, http: environment.http)
    }

    func testConnection() async {
        guard let url = parsedURL() else { return }
        let token = isSignedIn ? secret(.jellyfinAccessToken) : nil
        await perform {
            let check = try await client(url, token: token).testConnection()
            if var account = try environment.accounts.account(.jellyfin), account.baseURL == url {
                account.serverName = check.serverName
                account.serverVersion = check.version
                account.lastCheckedAt = .now
                try environment.accounts.save(account)
            }
            let user = check.user.map { " · \($0.name)" } ?? " · not signed in"
            return "Jellyfin \(check.version) · \(check.serverName)\(user)"
        }
    }

    /// Logs in with username/password, stores only the access token, and forgets the password.
    func signIn() async {
        guard let url = parsedURL() else { return }
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pw = password
        await perform {
            let client = client(url, token: nil)
            let info = try await client.publicSystemInfo()
            let auth = try await client.authenticate(username: name, password: pw)
            try saveAccount(
                ServerAccount(kind: .jellyfin, baseURL: url, username: auth.user.name, userId: auth.user.id,
                              serverName: info.serverName, serverVersion: info.version, lastCheckedAt: .now),
                secrets: [.jellyfinAccessToken: auth.accessToken]
            )
            password = ""
            return "Jellyfin \(info.version) · \(info.serverName) · \(auth.user.name)"
        }
    }

    /// Revokes the token on the server when reachable; always forgets it locally.
    func signOut() async {
        if let account = try? environment.accounts.account(.jellyfin) {
            let token = secret(.jellyfinAccessToken)
            if !token.isEmpty {
                try? await client(account.baseURL, token: token).signOut()
            }
        }
        remove(secrets: [.jellyfinAccessToken])
        password = ""
    }
}


/// How this device introduces itself to Jellyfin; the device id is made once and kept in the Keychain.
enum JellyfinIdentity {
    static func make(secrets: any SecretStore) -> JellyfinClientIdentity {
        let deviceId: String
        if let existing = try? secrets.secret(for: .jellyfinDeviceId) {
            deviceId = existing
        } else {
            deviceId = UUID().uuidString
            try? secrets.setSecret(deviceId, for: .jellyfinDeviceId)
        }
        return JellyfinClientIdentity(device: deviceName, deviceId: deviceId, version: CommonEnvironment.appVersion)
    }

    private static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.model
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }
}
