import Core
import Foundation

/// The public demo servers ("Try It with the Demo Servers"): their addresses and the shared
/// demo account, fetched when asked for rather than built in, so they can change (a password
/// reset nightly) or be switched off without an app update. Everything in it is public: the
/// account can't change anything, and the apps write nothing to it (`ServerAccount.isDemo`).
nonisolated public struct DemoConfig: Decodable, Equatable, Sendable {
    public struct Kavita: Decodable, Equatable, Sendable {
        public let url: URL
        public let apiKey: String
    }

    public struct SignIn: Decodable, Equatable, Sendable {
        public let url: URL
        public let user: String
        public let password: String
    }

    public let version: Int
    public let kavita: Kavita?
    public let jellyfin: SignIn?
    public let audiobookshelf: SignIn?
    /// Shown with the button when set ("Back tomorrow").
    public let message: String?

    /// The only shape this build reads.
    static let supportedVersion = 1

    /// Where the demo's details are published.
    public static let address = URL(string: "https://demo.amatsubame.com/config.json")!

    public enum Failure: LocalizedError, Equatable {
        case unavailable
        case newerVersion

        public var errorDescription: String? {
            switch self {
            case .unavailable: "The demo isn't available right now."
            case .newerVersion: "The demo needs a newer version of the app."
            }
        }
    }

    /// Reads the published details. Debug builds can use `DEMO_CONFIG` instead (a file path or
    /// address), for tests and before the address is live.
    public static func fetch(http: HTTPClient) async throws -> DemoConfig {
        let data: Data
        do {
            #if DEBUG
            if let override = ProcessInfo.processInfo.environment["DEMO_CONFIG"], !override.isEmpty {
                let url = override.hasPrefix("http") ? URL(string: override) : URL(filePath: override)
                if let url, url.isFileURL {
                    return try parse(try Data(contentsOf: url))
                } else if let url {
                    data = try await http.send(URLRequest(url: url)).data
                    return try parse(data)
                }
            }
            #endif
            data = try await http.send(URLRequest(url: address)).data
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unavailable
        }
        return try parse(data)
    }

    /// The published JSON, or why it can't be used.
    public static func parse(_ data: Data) throws -> DemoConfig {
        struct Version: Decodable { let version: Int }
        guard let version = try? JSONDecoder().decode(Version.self, from: data).version else { throw Failure.unavailable }
        guard version <= supportedVersion else { throw Failure.newerVersion }
        guard let config = try? JSONDecoder().decode(DemoConfig.self, from: data) else { throw Failure.unavailable }
        return config
    }
}
