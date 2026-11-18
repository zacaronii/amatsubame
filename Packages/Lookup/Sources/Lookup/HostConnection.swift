import Dictionary
import Foundation
import HachidoriKit
import Network
import Observation

/// The link to a Hachidori host as the popup sees it (Settings ▸ Hachidori): whether it's linked,
/// the host's settings, styles and known/ignored words, and the requests a lookup makes. Anything
/// that fails returns nil, so the caller falls back to the local dictionaries (unlike Hachidori,
/// which fails while its host is away).
@MainActor @Observable
public final class HostConnection {
    @ObservationIgnored public let link: HachidoriLink
    public private(set) var status: HachidoriLink.Status = .stopped
    public private(set) var options = HostOptions(nil)
    public private(set) var wordStatus = WordStatusOverrides()
    public private(set) var dictionaries: [HostDictionary] = []
    /// The host's hello while linked: its name, version and dictionary count.
    public private(set) var hello: HostHello?
    /// When the host's records last came in (linking, or a change on the host).
    public private(set) var lastSynced: Date?
    /// Called each time the link comes up (to send what was queued meanwhile).
    @ObservationIgnored public var onLinked: (@MainActor () -> Void)?
    /// Called with the host's settings whenever they come in.
    @ObservationIgnored var onOptions: (@MainActor (HostOptions) -> Void)?
    /// Called with the host's known and ignored words whenever they come in.
    @ObservationIgnored var onWordStatus: (@MainActor (WordStatusOverrides) -> Void)?
    /// Each host dictionary's CSS, fetched once per link.
    public private(set) var styles: [String: String] = [:]
    @ObservationIgnored private var observing: Task<Void, Never>?
    /// Tells the link when the network goes and comes back (airplane mode).
    @ObservationIgnored private var network: (monitor: NWPathMonitor, task: Task<Void, Never>)?
    /// How long a tap waits for the host before looking up locally.
    static let lookupTimeout: Duration = .seconds(3)

    public init(link: HachidoriLink) {
        self.link = link
    }

    public convenience init?(address: String, clientName: String, clientVersion: String) {
        guard let url = HachidoriLink.linkURL(from: address) else { return nil }
        self.init(link: HachidoriLink(url: url, clientName: clientName, clientVersion: clientVersion))
    }

    public var isLinked: Bool {
        if case .linked = status { true } else { false }
    }

    public func start() {
        guard observing == nil else { return }
        let link = link
        observing = Task { [weak self] in
            let updates = await link.updates()
            await link.start()
            for await update in updates {
                guard let self else { return }
                await self.apply(update)
            }
        }
        let monitor = NWPathMonitor()
        let (paths, continuation) = AsyncStream.makeStream(of: Bool.self)
        monitor.pathUpdateHandler = { continuation.yield($0.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "HostConnection.network"))
        network = (monitor, Task {
            for await available in paths { await link.networkChanged(available: available) }
        })
    }

    public func stop() {
        observing?.cancel()
        observing = nil
        network?.monitor.cancel()
        network?.task.cancel()
        network = nil
        let link = link
        Task { await link.stop() }
        status = .stopped
    }

    private func apply(_ update: HachidoriLink.Update) async {
        switch update {
        case .status(let status):
            if case .linked = status {
                // Never linked without the host's settings in place.
                await refreshRecords()
                hello = await link.hello
                self.status = status
                onLinked?()
                styles = (try? await link.styles()) ?? [:]
            } else {
                self.status = status
            }
        case .records:
            await refreshRecords()
        case .wordStatus:
            break
        }
    }

    private func refreshRecords() async {
        let records = await link.records
        options = records.options
        wordStatus = records.wordStatus
        dictionaries = records.dictionaries
        lastSynced = Date()
        onOptions?(options)
        onWordStatus?(wordStatus)
    }

    /// Tries to link now instead of after the backoff (the app came to the front, or Sync Now).
    public func reconnectNow() {
        let link = link
        Task { await link.reconnectNow() }
    }

    /// The host's results for scanned text, or nil to look up locally.
    func lookup(_ text: String, maxResults: Int? = nil) async -> [TermLookupResult]? {
        guard isLinked else { return nil }
        return try? await link.lookup(text, maxResults: maxResults, timeout: Self.lookupTimeout).results
    }

    /// The host's count for a headword (0 before its first lookup there). Nil when it didn't answer.
    func lookupCount(term: String, reading: String) async -> Int? {
        guard isLinked else { return nil }
        do {
            return try await link.lookupCount(term: term, reading: reading, timeout: Self.lookupTimeout)?.lookupCount ?? 0
        } catch {
            return nil
        }
    }

    func media(dictionary: String, path: String) async -> Data? {
        guard isLinked else { return nil }
        return try? await link.mediaData(dictionary: dictionary, path: path)
    }
}
