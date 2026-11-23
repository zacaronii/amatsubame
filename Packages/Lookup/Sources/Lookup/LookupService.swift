import Core
import Dictionary
import Foundation
import GRDB
import HachidoriKit

/// The text a lookup came from, with the matched span (UTF-16 offsets).
public struct LookupSource: Equatable, Sendable {
    public var text: String
    public var utf16Offset: Int
    public var utf16Length: Int

    public init(text: String, utf16Offset: Int, utf16Length: Int) {
        self.text = text
        self.utf16Offset = utf16Offset
        self.utf16Length = utf16Length
    }
}

/// One screen of lookup results (the popup keeps a stack of these for recursive lookups).
public struct LookupResultPage: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// What was looked up (the scanned text, or the search query).
    public var query: String
    /// The sentence around a tap, for mining (phase 4); nil for searches.
    public var sentence: String?
    /// Shown above the results so another word can be tapped (readers, OCR blocks).
    public var source: LookupSource?
    public var results: [TermLookupResult]
    /// How often the first result's headword has been looked up, counting this visit; nil
    /// until the visit is recorded, or when lookup counts are off.
    public var lookupCount: Int?

    public init(query: String, sentence: String? = nil, source: LookupSource? = nil, results: [TermLookupResult],
                lookupCount: Int? = nil) {
        self.query = query
        self.sentence = sentence
        self.source = source
        self.results = results
        self.lookupCount = lookupCount
    }
}

/// The single lookup entry point for every reader, the player, the browser and
/// search. Readers call `lookup(text:utf16Offset:)` with the tapped block of text.
@MainActor @Observable
public final class LookupService {
    public let library: DictionaryLibrary
    public let audio: AudioService
    /// Set when Anki is available; adds the Add to Anki button to entries.
    public var mining: MiningService? {
        didSet { mining?.markedByHand = Set(wordStatuses.keys) }
    }
    public private(set) var styles: [String: String] = [:]
    /// Counts lookups for the Stats tab (the app's own database).
    public var activity: ActivityLog?
    /// The app's accent in the popup (buttons, highlights): CSS colors for the accent and for
    /// text on it. Nil keeps the system blue.
    public var accent: (color: String, onColor: String)?
    /// Lookup counts and the popup's settings, in the setup's database (shared by the apps).
    public let counts: LookupCountStore
    /// Settings ▸ Popup as stored in the setup (shared by the apps).
    public private(set) var storedPopupSettings: PopupSettings
    /// Settings ▸ Hachidori: the linked host. Its counts and popup settings apply on every
    /// platform; lookups go to it only with `looksUpOnHost`. Nil: nothing is shared.
    public var host: HostConnection? {
        didSet {
            guard oldValue !== host else { return }
            oldValue?.stop()
            // No host: the sort dictionary's own order again.
            if host == nil { Task { [library] in try? await library.setHostFrequencyOrder(nil) } }
            host?.onOptions = { [weak self] options in self?.keep(options) }
            host?.onWordStatus = { [weak self] overrides in self?.adopt(overrides) }
        }
    }
    /// Words are looked up on the host while it's linked (the Mac apps). iPhone and iPad look up
    /// with their own copies, which stay fast and work anywhere (docs/hachidori.md section 8).
    public var looksUpOnHost = false
    /// Where lookups to count and word marks for the host wait (the app's outbox), and what sends them.
    public var hostOutbox: (outbox: OutboxStore, queued: @MainActor () -> Void)?
    /// Words marked known or ignored by hand, in the setup's database (shared by the apps).
    public let wordStatusStore: WordStatusStore
    /// Whether Hachidori is on (Settings ▸ Hachidori), linked or not: marks then wait for it.
    public var sharesWithHost: () -> Bool = { false }
    /// Those marks, by headword.
    public private(set) var wordStatuses: [String: WordStatus] = [:]
    /// Linked to a Hachidori host: counts and the popup's settings are the host's.
    public var followsHost: Bool { host?.isLinked == true }
    /// Settings ▸ Popup in effect: the host's while linked (Hachidori's options), else ours,
    /// which keep the host's last ones (so they hold offline).
    public var popupSettings: PopupSettings {
        guard followsHost, let options = host?.options else { return storedPopupSettings }
        return Self.settings(storedPopupSettings, following: options)
    }

    static func settings(_ settings: PopupSettings, following options: HostOptions) -> PopupSettings {
        var settings = settings
        settings.showLookupCounts = options.showLookupCounts
        settings.showCompactDefinitionSummary = options.showCompactDefinitionSummary
        settings.compactDefinitionSummaryCount = options.compactDefinitionSummaryCount
        settings.compactDefinitionSummaryDictionary = options.compactDefinitionSummaryDictionary.isEmpty
            ? nil : options.compactDefinitionSummaryDictionary
        settings.backgroundOpacityPercent = options.popupOpacityPercent
        return settings
    }

    /// Saves the host's popup settings as ours, for when it isn't reachable.
    private func keep(_ options: HostOptions) {
        let following = Self.settings(storedPopupSettings, following: options)
        if following != storedPopupSettings { updatePopupSettings { $0 = following } }
        // The host's frequency order, when it names one, sorts the lookups here too.
        let order = FrequencyOrder(hostSetting: options.frequencyOrder)
        Task { [library] in try? await library.setHostFrequencyOrder(order) }
    }
    /// Settings ▸ Popup ▸ Lookup Counts: count lookups and show "Looked up N times".
    public var showsLookupCounts: Bool { popupSettings.showLookupCounts }
    private let database: AppDatabase
    static let historyLimit = 500

    /// `history`: where lookup history goes (the app's own database), when the dictionaries
    /// live in a shared setup; defaults to the library's database.
    public init(library: DictionaryLibrary, audio: AudioService, history: AppDatabase? = nil) {
        self.library = library
        self.audio = audio
        database = history ?? library.database
        counts = LookupCountStore(database: library.database)
        storedPopupSettings = (try? counts.settings()) ?? PopupSettings()
        wordStatusStore = WordStatusStore(database: library.database)
        wordStatuses = (try? wordStatusStore.statuses()) ?? [:]
    }

    // MARK: Known and ignored words

    /// Re-reads the marks (another app may have changed them) and hands them to the word marks.
    public func reloadWordStatuses() {
        let statuses = (try? wordStatusStore.statuses()) ?? [:]
        if statuses != wordStatuses { wordStatuses = statuses }
        mining?.markedByHand = Set(statuses.keys)
    }

    public func wordStatus(of headword: String) -> WordStatus? {
        wordStatuses[WordStatusStore.normalized(headword)]
    }

    /// The popup's Known or Ignore: sets the word to `status`, or clears it when it already has
    /// it (as Hachidori's toggles do). With a Hachidori host on, the change is queued for it.
    /// Returns the word's mark afterwards.
    @discardableResult
    public func toggleWordStatus(_ status: WordStatus, for headword: String) -> WordStatus? {
        let next: WordStatus? = wordStatus(of: headword) == status ? nil : status
        setWordStatus(next, for: [headword])
        return next
    }

    /// Marks words known or ignored, or clears them (nil).
    public func setWordStatus(_ status: WordStatus?, for headwords: [String]) {
        for headword in headwords {
            try? wordStatusStore.set(status, for: headword, host: sharesWithHost())
            try? hostOutbox?.outbox.queueHostWordStatus(headword)
        }
        hostOutbox?.queued()
        reloadWordStatuses()
    }

    /// Settings ▸ Known Words ▸ Add: marks a list of words known.
    @discardableResult
    public func addKnownWords(_ headwords: [String]) -> Int {
        let added = (try? wordStatusStore.addKnown(headwords, host: sharesWithHost())) ?? 0
        if hostOutbox != nil {
            for headword in headwords { try? hostOutbox?.outbox.queueHostWordStatus(headword) }
            hostOutbox?.queued()
        }
        reloadWordStatuses()
        return added
    }

    /// The host's list came in: it becomes ours, except for changes it hasn't had yet.
    private func adopt(_ overrides: WordStatusOverrides) {
        if (try? wordStatusStore.adoptHost(known: overrides.known, ignored: overrides.ignored)) == true { reloadWordStatuses() }
    }

    public func setShowsLookupCounts(_ shows: Bool) {
        updatePopupSettings { $0.showLookupCounts = shows }
    }

    /// Changes Settings ▸ Popup; pages built afterwards follow it.
    public func updatePopupSettings(_ change: (inout PopupSettings) -> Void) {
        change(&storedPopupSettings)
        try? counts.save(storedPopupSettings)
    }

    /// Re-reads the shared settings (another app may have changed them).
    public func reloadPopupSettings() {
        if let settings = try? counts.settings() { storedPopupSettings = settings }
    }

    /// Loads installed dictionaries into the engine (call at launch and after changes).
    public func reload() async throws {
        try await library.reloadEngine()
        styles = await library.engine.styles()
        reloadPopupSettings()
    }

    /// Looks up from the tapped character of `text` onward. With `showSource`, the
    /// popup shows `text` above the results with the match highlighted.
    public func lookup(text: String, utf16Offset: Int, showSource: Bool = false) async -> LookupResultPage {
        let scanned = TextScanner.scanText(text, utf16Offset: utf16Offset)
        let results = NameRanking.forTextTap(await terms(scanned))
        let matched = results.first?.matched ?? ""
        let page = LookupResultPage(
            query: results.first?.matched ?? scanned,
            sentence: TextScanner.sentence(in: text, utf16Offset: utf16Offset),
            source: showSource ? LookupSource(text: text, utf16Offset: utf16Offset, utf16Length: matched.utf16.count) : nil,
            results: results
        )
        if !results.isEmpty { try? activity?.recordLookup() }
        return await record(page)
    }

    /// Looks up typed text (the search screen and glossary links).
    public func search(_ query: String) async -> LookupResultPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return LookupResultPage(query: trimmed, results: await terms(trimmed, maxResults: 32))
    }

    /// The host's results while linked, else (or when it doesn't answer) the local dictionaries',
    /// with Jitendex's redirects (精いっぱい → 精一杯) followed.
    private func terms(_ text: String, maxResults: Int? = nil) async -> [TermLookupResult] {
        let results = await rawTerms(text, maxResults: maxResults)
        var found: [String: [TermLookupResult]] = [:]
        for term in Redirects.terms(in: results) { found[term] = await rawTerms(term, maxResults: 8) }
        return Redirects.follow(results, found: found)
    }

    private func rawTerms(_ text: String, maxResults: Int? = nil) async -> [TermLookupResult] {
        if looksUpOnHost, !text.isEmpty, let host, let found = await host.lookup(text, maxResults: maxResults) { return found }
        if let maxResults { return await library.engine.lookup(text, maxResults: maxResults) }
        return await library.engine.lookup(text)
    }

    /// A typed search the user settled on (submitted): kept in history and counted, like a
    /// lookup (searches as you type aren't counted). Returns its lookup count.
    @discardableResult
    public func recordSearch(_ page: LookupResultPage) async -> Int? {
        guard !page.results.isEmpty else { return nil }
        try? activity?.recordLookup()
        return await record(page).lookupCount
    }

    /// One visit to a page of results (a tap, a link in a definition, a submitted search):
    /// kept in history, and counted the way Hachidori counts lookups: +1 for the first result's
    /// headword and reading, once per visit (Back and re-rendering don't count again).
    ///
    /// With a Hachidori host set, the lookup is also queued for it (`hd_lookup_stats_record`
    /// through the outbox, so it's sent when the host is reachable), and while linked the count
    /// shown is the host's plus what's still queued, which the word's own count then takes.
    @discardableResult
    public func record(_ page: LookupResultPage) async -> LookupResultPage {
        guard let first = page.results.first else { return page }
        var page = page
        if showsLookupCounts {
            page.lookupCount = (try? counts.record(term: first.expression, reading: first.reading))?.lookupCount
            if let host, let hostOutbox {
                try? hostOutbox.outbox.queueHostLookupCount(term: first.expression, reading: first.reading)
                hostOutbox.queued()
                if let counted = await host.lookupCount(term: first.expression, reading: first.reading),
                   let queued = try? hostOutbox.outbox.queuedHostLookupCount(term: first.expression, reading: first.reading) {
                    page.lookupCount = counted + queued
                    try? counts.setCount(term: first.expression, reading: first.reading, to: counted + queued)
                }
            }
        }
        let entry = LookupHistoryRecord(query: page.query, expression: first.expression, reading: first.reading)
        let limit = Self.historyLimit
        try? await database.writer.write { db in
            var entry = entry
            _ = try LookupHistoryRecord.filter(Column("expression") == entry.expression && Column("reading") == entry.reading).deleteAll(db)
            try entry.insert(db)
            try db.execute(sql: """
                DELETE FROM lookupHistory WHERE id NOT IN (SELECT id FROM lookupHistory ORDER BY createdAt DESC, id DESC LIMIT ?)
                """, arguments: [limit])
        }
        return page
    }

    public func observeHistory(limit: Int = 50) -> AsyncThrowingStream<[LookupHistoryRecord], any Error> {
        database.values { db in
            try LookupHistoryRecord.order(Column("createdAt").desc, Column("id").desc).limit(limit).fetchAll(db)
        }
    }

    public func clearHistory() {
        _ = try? database.writer.write { try LookupHistoryRecord.deleteAll($0) }
    }

    /// How strong the text halo is at a background opacity: 1 at 0 %, fading to 0 by 70 %, where
    /// the popup colour alone keeps text readable.
    public static func haloStrength(opacityPercent: Int) -> Double {
        max(0, 1 - Double(min(max(opacityPercent, 0), 100)) / 70)
    }

    /// The full HTML document for a page of results. With `nativeBackground`, the page stays
    /// transparent and the view showing it draws the background (`LookupPopupView`).
    public func document(for page: LookupResultPage, nativeBackground: Bool = false) -> String {
        let source = page.source.map(EntryRenderer.source) ?? ""
        let mined = mining.map { mining in page.results.map(mining.isMined) }
        // Known and Ignore while words are marked, as in Hachidori (they're about the marks).
        let statuses = mining?.marksWords == true ? page.results.map { wordStatus(of: $0.expression) } : nil
        let setting = min(max(popupSettings.backgroundOpacityPercent, 0), 100)
        let opacity = nativeBackground ? 0 : setting
        let halo = Self.haloStrength(opacityPercent: setting)
        let accentCSS = (accent.map { ":root { --accent: \($0.color); --on-accent: \($0.onColor); }" } ?? "")
            + ":root { --popup-opacity: \(opacity)%; --popup-halo: \(String(format: "%.3f", halo)); }"
        let count: EntryRenderer.LookupCount? = showsLookupCounts ? .init(page.lookupCount) : nil
        let summary: EntryRenderer.SummaryOptions? = popupSettings.showCompactDefinitionSummary
            ? .init(dictionary: popupSettings.compactDefinitionSummaryDictionary, count: popupSettings.compactDefinitionSummaryCount)
            : nil
        let dictionaryStyles = looksUpOnHost && followsHost ? styles.merging(host?.styles ?? [:]) { $1 } : styles
        return LookupPage.document(body: source + EntryRenderer.entries(page.results, mined: mined, statuses: statuses, lookupCount: count, summary: summary),
                                   dictionaryStyles: dictionaryStyles, extraCSS: accentCSS)
    }

    /// A dictionary image for the popup: from the local dictionaries, else from the host.
    func mediaFile(dictionary: String, path: String) async -> Data? {
        if let data = await library.engine.mediaFile(dictionary: dictionary, path: path) { return data }
        guard looksUpOnHost else { return nil }
        return await host?.media(dictionary: dictionary, path: path)
    }
}
