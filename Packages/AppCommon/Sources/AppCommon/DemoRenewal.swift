import Core
import Foundation

/// The demo servers are reset every night, which can undo a saved sign-in (Jellyfin's token
/// goes with the reset). A demo account's sign-in is checked at launch and on coming back;
/// when the server refuses it, the app signs in again with the published details, once.
/// Anything else (offline, the server down) leaves it alone.
public enum DemoRenewal {
    public enum Check: Sendable {
        case fine, refused, unknown
    }

    /// Runs `attempt` (a request needing the saved sign-in): refused only for 401 or 403.
    public static func check(_ attempt: () async throws -> Void) async -> Check {
        do {
            try await attempt()
            return .fine
        } catch {
            if case .unauthorized? = error as? ConnectionError { return .refused }
            return .unknown
        }
    }

    /// For a demo account of `kind`: `check` the saved sign-in, and when it's refused,
    /// `signIn` with fresh details. Returns whether it signed in again.
    @MainActor @discardableResult
    public static func renew(_ environment: CommonEnvironment, kind: ServerKind, check: () async -> Check,
                             fetch: ((HTTPClient) async throws -> DemoConfig)? = nil,
                             signIn: (DemoConfig) async -> Bool) async -> Bool {
        // At launch, the saved accounts are read first.
        for _ in 0..<50 where !environment.accountsLoaded { try? await Task.sleep(for: .milliseconds(100)) }
        guard environment.serverAccounts[kind]?.isDemo == true, await check() == .refused else { return false }
        let fetch = fetch ?? { try await DemoConfig.fetch(http: $0) }
        guard let config = try? await fetch(environment.http) else { return false }
        return await signIn(config)
    }
}
