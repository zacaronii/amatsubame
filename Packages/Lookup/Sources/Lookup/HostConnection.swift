import Dictionary
import Foundation
import HachidoriKit
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
    public private(set) var wordStatus = WordStatusOverrides() {
        didSet { unmarked = Set(wordStatus.known + wordStatus.ignored) }
    }
    @ObservationIgnored private var unmarked: Set<String> = []
    public private(set) var dictionaries: [HostDictionary] = []
    /// The host's hello while linked: its name, version and dictionary count.
    public private(set) var hello: HostHello?
    /// Each host dictionary's CSS, fetched once per link.
    public private(set) var styles: [String: String] = [:]
    @ObservationIgnored private var observing: Task<Void, Never>?
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
    }

    public func stop() {
        observing?.cancel()
        observing = nil
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
    }

    /// The host's results for scanned text, or nil to look up locally.
    func lookup(_ text: String, maxResults: Int? = nil) async -> [TermLookupResult]? {
        guard isLinked else { return nil }
        return try? await link.lookup(text, maxResults: maxResults, timeout: Self.lookupTimeout).results
    }

    /// Counts a lookup on the host. Nil when the host doesn't count lookups or didn't answer.
    func recordLookup(term: String, reading: String) async -> Int? {
        guard isLinked, options.showLookupCounts else { return nil }
        return try? await link.recordLookup(term: term, reading: reading, timeout: Self.lookupTimeout)?.lookupCount
    }

    func media(dictionary: String, path: String) async -> Data? {
        guard isLinked else { return nil }
        return try? await link.mediaData(dictionary: dictionary, path: path)
    }

    /// Marked known or ignored on the host: such words get no word mark (as in Hachidori).
    func hidesMark(for headword: String) -> Bool {
        unmarked.contains(headword)
    }
}
