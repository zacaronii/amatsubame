import AppCommon
import Core
import Foundation
import KavitaKit
import Observation

@Observable
final class KavitaSettingsModel: ServerSettingsModel {
    var authKey = ""

    init(environment: CommonEnvironment) {
        super.init(kind: .kavita, environment: environment)
        authKey = secret(.kavitaAuthKey)
    }

    var canTest: Bool { !urlText.isEmpty && !authKey.isEmpty && status != .working }

    /// Tests the form's values and saves them when the server accepts them.
    func testAndSave() async {
        guard let url = parsedURL() else { return }
        let key = authKey.trimmingCharacters(in: .whitespacesAndNewlines)
        await perform {
            let check = try await KavitaClient(baseURL: url, authKey: key, http: environment.http).testConnection()
            try saveAccount(
                ServerAccount(kind: .kavita, baseURL: url, username: check.username,
                              serverName: "Kavita", serverVersion: check.version, lastCheckedAt: .now),
                secrets: [.kavitaAuthKey: key]
            )
            return "Kavita \(check.version) · signed in as \(check.username)"
        }
    }

    func remove() {
        remove(secrets: [.kavitaAuthKey])
        authKey = ""
    }
}

