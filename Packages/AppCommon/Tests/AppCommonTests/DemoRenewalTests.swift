import AppCommon
import Core
import Foundation
import Testing

/// Signing in again to a demo server after its nightly reset: only a demo account, only when
/// the server refuses the saved sign-in, and with the freshly fetched details.
@MainActor @Suite struct DemoRenewalTests {
    static let config = try! DemoConfig.parse(Data(#"{"version": 1, "kavita": {"url": "https://kavita.example.com", "apiKey": "new-key"}}"#.utf8))

    func environment(demo: Bool?) async throws -> CommonEnvironment {
        let temp = FileManager.default.temporaryDirectory.appending(path: "renew-\(UUID().uuidString)")
        let common = CommonEnvironment(database: try AppDatabase.inMemory(), secrets: InMemorySecretStore(),
                                       mediaDirectory: temp.appending(path: "Media"), dictionaryDirectory: temp.appending(path: "Dictionaries"))
        common.dictionaryUpdater.isEnabled = false
        if let demo { try common.accounts.save(ServerAccount(kind: .kavita, baseURL: URL(string: "https://kavita.example.com")!, isDemo: demo)) }
        Task { await common.start() }
        for _ in 0..<50 where !common.accountsLoaded || (demo != nil && common.serverAccounts[.kavita] == nil) {
            try await Task.sleep(for: .milliseconds(20))
        }
        return common
    }

    func renew(_ common: CommonEnvironment, check: DemoRenewal.Check) async -> String? {
        var signedInWith: String?
        await DemoRenewal.renew(common, kind: .kavita, check: { check }, fetch: { _ in Self.config }) { config in
            signedInWith = config.kavita?.apiKey
            return true
        }
        return signedInWith
    }

    @Test func aRefusedDemoSignInIsRenewedWithTheFreshDetails() async throws {
        #expect(await renew(try await environment(demo: true), check: .refused) == "new-key")
    }

    @Test func aWorkingOrUnreachableDemoIsLeftAlone() async throws {
        let common = try await environment(demo: true)
        #expect(await renew(common, check: .fine) == nil)
        #expect(await renew(common, check: .unknown) == nil, "offline or down isn't a refusal")
    }

    @Test func yourOwnServerIsNeverTouched() async throws {
        #expect(await renew(try await environment(demo: false), check: .refused) == nil)
        #expect(await renew(try await environment(demo: nil), check: .refused) == nil)
    }

    @Test func onlyUnauthorizedCountsAsRefused() async {
        #expect(await DemoRenewal.check { throw ConnectionError.unauthorized } == .refused)
        #expect(await DemoRenewal.check { throw ConnectionError.server(status: 500) } == .unknown)
        #expect(await DemoRenewal.check {} == .fine)
    }
}
