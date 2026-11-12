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

    public init(query: String, sentence: String? = nil, source: LookupSource? = nil, results: [TermLookupResult]) {
        self.query = query
        self.sentence = sentence
        self.source = source
        self.results = results
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
    private let database: AppDatabase
    static let historyLimit = 500

    /// `history`: where lookup history goes (the app's own database), when the dictionaries
    /// live in a shared setup; defaults to the library's database.
    public init(library: DictionaryLibrary, audio: AudioService, history: AppDatabase? = nil) {
        self.library = library
        self.audio = audio
        database = history ?? library.database
    }

    /// Loads installed dictionaries into the engine (call at launch and after changes).
    public func reload() async throws {
        try await library.reloadEngine()
        styles = await library.engine.styles()
    }

    /// Looks up from the tapped character of `text` onward. With `showSource`, the
    /// popup shows `text` above the results with the match highlighted.
    public func lookup(text: String, utf16Offset: Int, showSource: Bool = false) async -> LookupResultPage {
        let scanned = TextScanner.scanText(text, utf16Offset: utf16Offset)
        let results = await library.engine.lookup(scanned)
        let matched = results.first?.matched ?? ""
        let page = LookupResultPage(
            query: results.first?.matched ?? scanned,
            sentence: TextScanner.sentence(in: text, utf16Offset: utf16Offset),
            source: showSource ? LookupSource(text: text, utf16Offset: utf16Offset, utf16Length: matched.utf16.count) : nil,
            results: results
        )
        record(page)
        if !results.isEmpty { try? activity?.recordLookup() }
        return page
    }

    /// Looks up typed text (the search screen and glossary links).
    public func search(_ query: String) async -> LookupResultPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = LookupResultPage(query: trimmed, results: await library.engine.lookup(trimmed, maxResults: 32))
        return page
    }

    /// A typed search the user settled on (submitted): kept in history and counted in Stats,
    /// like a lookup (searches as you type aren't counted).
    public func recordSearch(_ page: LookupResultPage) {
        guard !page.results.isEmpty else { return }
        record(page)
        try? activity?.recordLookup()
    }

    public func record(_ page: LookupResultPage) {
        guard let first = page.results.first else { return }
        let entry = LookupHistoryRecord(query: page.query, expression: first.expression, reading: first.reading)
        try? database.writer.write { db in
            var entry = entry
            _ = try LookupHistoryRecord.filter(Column("expression") == entry.expression && Column("reading") == entry.reading).deleteAll(db)
            try entry.insert(db)
            try db.execute(sql: """
                DELETE FROM lookupHistory WHERE id NOT IN (SELECT id FROM lookupHistory ORDER BY createdAt DESC, id DESC LIMIT ?)
                """, arguments: [Self.historyLimit])
        }
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
        return LookupPage.document(body: source + EntryRenderer.entries(page.results, mined: mined), dictionaryStyles: styles,
                                   extraCSS: accentCSS)
    }
}
