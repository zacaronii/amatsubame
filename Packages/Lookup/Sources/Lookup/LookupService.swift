import Core
import Dictionary
import Foundation
import GRDB

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
    public var mining: MiningService?
    public private(set) var styles: [String: String] = [:]
    /// Counts lookups for the Stats tab (the app's own database).
    public var activity: ActivityLog?
    /// The app's accent in the popup (buttons, highlights): CSS colors for the accent and for
    /// text on it. Nil keeps the system blue.
    public var accent: (color: String, onColor: String)?
    /// Lookup counts and the popup's settings, in the setup's database (shared by the apps).
    public let counts: LookupCountStore
    /// Settings ▸ Popup, shared by the apps.
    public private(set) var popupSettings: PopupSettings
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
        popupSettings = (try? counts.settings()) ?? PopupSettings()
    }

    public func setShowsLookupCounts(_ shows: Bool) {
        updatePopupSettings { $0.showLookupCounts = shows }
    }

    /// Changes Settings ▸ Popup; pages built afterwards follow it.
    public func updatePopupSettings(_ change: (inout PopupSettings) -> Void) {
        change(&popupSettings)
        try? counts.save(popupSettings)
    }

    /// Re-reads the shared settings (another app may have changed them).
    public func reloadPopupSettings() {
        if let settings = try? counts.settings() { popupSettings = settings }
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
        let results = NameRanking.forTextTap(await library.engine.lookup(scanned))
        let matched = results.first?.matched ?? ""
        let page = LookupResultPage(
            query: results.first?.matched ?? scanned,
            sentence: TextScanner.sentence(in: text, utf16Offset: utf16Offset),
            source: showSource ? LookupSource(text: text, utf16Offset: utf16Offset, utf16Length: matched.utf16.count) : nil,
            results: results
        )
        if !results.isEmpty { try? activity?.recordLookup() }
        return record(page)
    }

    /// Looks up typed text (the search screen and glossary links).
    public func search(_ query: String) async -> LookupResultPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = LookupResultPage(query: trimmed, results: await library.engine.lookup(trimmed, maxResults: 32))
        return page
    }

    /// A typed search the user settled on (submitted): kept in history and counted, like a
    /// lookup (searches as you type aren't counted). Returns its lookup count.
    @discardableResult
    public func recordSearch(_ page: LookupResultPage) -> Int? {
        guard !page.results.isEmpty else { return nil }
        try? activity?.recordLookup()
        return record(page).lookupCount
    }

    /// One visit to a page of results (a tap, a link in a definition, a submitted search):
    /// kept in history, and counted the way Hachidori counts lookups: +1 for the first result's
    /// headword and reading, once per visit (Back and re-rendering don't count again).
    @discardableResult
    public func record(_ page: LookupResultPage) -> LookupResultPage {
        guard let first = page.results.first else { return page }
        var page = page
        if showsLookupCounts {
            page.lookupCount = (try? counts.record(term: first.expression, reading: first.reading))?.lookupCount
        }
        let entry = LookupHistoryRecord(query: page.query, expression: first.expression, reading: first.reading)
        try? database.writer.write { db in
            var entry = entry
            _ = try LookupHistoryRecord.filter(Column("expression") == entry.expression && Column("reading") == entry.reading).deleteAll(db)
            try entry.insert(db)
            try db.execute(sql: """
                DELETE FROM lookupHistory WHERE id NOT IN (SELECT id FROM lookupHistory ORDER BY createdAt DESC, id DESC LIMIT ?)
                """, arguments: [Self.historyLimit])
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

    /// The full HTML document for a page of results.
    public func document(for page: LookupResultPage) -> String {
        let source = page.source.map(EntryRenderer.source) ?? ""
        let mined = mining.map { mining in page.results.map(mining.isMined) }
        let accentCSS = accent.map { ":root { --accent: \($0.color); --on-accent: \($0.onColor); }" } ?? ""
        let count: EntryRenderer.LookupCount? = showsLookupCounts ? .init(page.lookupCount) : nil
        let summary: EntryRenderer.SummaryOptions? = popupSettings.showCompactDefinitionSummary
            ? .init(dictionary: popupSettings.compactDefinitionSummaryDictionary, count: popupSettings.compactDefinitionSummaryCount)
            : nil
        return LookupPage.document(body: source + EntryRenderer.entries(page.results, mined: mined, lookupCount: count, summary: summary),
                                   dictionaryStyles: styles, extraCSS: accentCSS)
    }
}
