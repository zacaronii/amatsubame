import Core
import Foundation

/// Asks the AnkiConnect server to sync with AnkiWeb a little after cards are
/// added, once per batch, when the user turned that on.
public actor AnkiSyncScheduler {
    public enum Outcome: Equatable, Sendable {
        case synced(Date)
        case failed(Date, String)
    }

    /// Wait this long after the last card so a burst of mining syncs once.
    let delay: Duration
    /// A sync that was already running (e.g. a scheduled one on the server) may have
    /// started before the new cards; try again after this.
    let busyRetryDelay: Duration
    let makeClient: @Sendable () throws -> AnkiConnectClient?
    let isEnabled: @Sendable () -> Bool
    private var pending: Task<Void, Never>?
    public private(set) var lastOutcome: Outcome?

    public init(
        delay: Duration = .seconds(10), busyRetryDelay: Duration = .seconds(60),
        makeClient: @escaping @Sendable () throws -> AnkiConnectClient?, isEnabled: @escaping @Sendable () -> Bool
    ) {
        self.delay = delay
        self.busyRetryDelay = busyRetryDelay
        self.makeClient = makeClient
        self.isEnabled = isEnabled
    }

    /// Call after a card reaches Anki.
    public func cardAdded() {
        guard isEnabled() else { return }
        pending?.cancel()
        pending = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.syncNow()
        }
    }

    /// Syncs now; if another sync is running, waits once and tries again.
    @discardableResult
    public func syncNow() async -> Outcome {
        var outcome = await attempt()
        if case .failed(_, let message) = outcome, message.localizedCaseInsensitiveContains("in progress") {
            try? await Task.sleep(for: busyRetryDelay)
            outcome = await attempt()
        }
        lastOutcome = outcome
        return outcome
    }

    private func attempt() async -> Outcome {
        do {
            guard let client = try makeClient() else { return .failed(Date(), "AnkiConnect isn't set up.") }
            try await client.sync()
            return .synced(Date())
        } catch {
            return .failed(Date(), error.localizedDescription)
        }
    }
}
