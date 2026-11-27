import Core
import Dictionary
import Foundation
import HachidoriKit
import Lookup
import Testing

/// Our tap lookup against Hachidori's own engine, over a corpus of taps. Run by
/// `scripts/hachidori-parity.sh`, in two steps sharing `PARITY_WORK`:
///
/// 1. Without `PARITY_REFERENCE`: copies a Hachidori host's dictionaries (read only, as Settings ▸
///    Hachidori ▸ Dictionaries does: its order and on/off) into `PARITY_WORK/dictionaries`, and
///    writes what Hachidori's popup would look up for each tap (`texts.txt`), the dictionaries
///    (`manifest.json`) and the host's frequency sorting (`options.json`), which our side follows
///    too, as a linked app does.
/// 2. With `PARITY_REFERENCE` (Hachidori's release engine run on those, by
///    `scripts/parity-reference.mjs`): compares each tap. Our deliberate rules are applied to
///    Hachidori's results first (redirects as Yomitan ranks them, converted names after words), so
///    only real differences remain.
///
/// `PARITY_CORPUS=<file.tsv>` (`source\tline\tutf16Offset` per tap) runs that corpus and writes every
/// lookup to `PARITY_OUTPUT` for `scripts/parity-report.py`; without it, the committed sample
/// (`Fixtures/parity-sample.tsv`) runs and must match outright.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PARITY_WORK"] != nil))
@MainActor struct HachidoriParityTests {
    struct Tap {
        var source: String
        var line: String
        var utf16Offset: Int
    }

    /// What's compared for one result.
    struct Entry: Codable, Equatable {
        var expression: String
        var reading: String
        var matched: String
        var dictionaries: [String]
        var inflections: [String]
        var preprocessorSteps: Int

        init(_ result: TermLookupResult) {
            expression = result.expression
            reading = result.reading
            matched = result.matched
            var seen = Set<String>()
            dictionaries = result.glossaries.map(\.dictionary).filter { seen.insert($0).inserted }
            inflections = result.inflections.map(\.name)
            preprocessorSteps = result.preprocessorSteps
        }
    }

    struct Record: Codable {
        var source: String
        var line: String
        var utf16Offset: Int
        var scanned: String
        var hachidoriText: String
        /// The app's tap lookup (`LookupService.lookup(text:utf16Offset:)`).
        var ours: [Entry]
        /// Hachidori's engine, raw, and with our deliberate rules applied: what `ours` should equal.
        var hachidoriRaw: [Entry]
        var expected: [Entry]
    }

    /// Per looked-up text, Hachidori's page and the pages of the redirect targets it names.
    typealias Reference = [String: (page: [TermLookupResult], targets: [String: [TermLookupResult]])]

    @Test func matchesHachidori() async throws {
        let environment = ProcessInfo.processInfo.environment
        let work = URL(filePath: try #require(environment["PARITY_WORK"]))
        let corpus = environment["PARITY_CORPUS"]
        let taps = try Self.taps(corpus.map { URL(filePath: $0) }
            ?? #require(Bundle.module.url(forResource: "parity-sample", withExtension: "tsv", subdirectory: "Fixtures")))
        let (service, options) = try await Self.service(dictionaries: work.appending(path: "dictionaries"))

        guard let referenceFile = environment["PARITY_REFERENCE"] else {
            var seen = Set<String>()
            let texts = taps.map { Self.hachidoriScan($0.line, utf16Offset: $0.utf16Offset) }.filter { !$0.isEmpty && seen.insert($0).inserted }
            try (texts.joined(separator: "\n") + "\n").write(to: work.appending(path: "texts.txt"), atomically: true, encoding: .utf8)
            // Hachidori's engine runs with the host's own frequency sorting.
            let engineOptions = ["frequencyDictionary": options.frequencyDictionary, "frequencyOrder": options.frequencyOrder, "primaryReading": ""]
            try JSONSerialization.data(withJSONObject: engineOptions, options: [.sortedKeys]).write(to: work.appending(path: "options.json"))
            print("Parity: prepared \(texts.count) texts for \(taps.count) taps")
            return
        }
        let reference = try Self.reference(URL(filePath: referenceFile))
        let output = environment["PARITY_OUTPUT"].map { URL(filePath: $0) }
        if let output { FileManager.default.createFile(atPath: output.path(percentEncoded: false), contents: Data()) }
        let handle = output.flatMap { try? FileHandle(forWritingTo: $0) }
        defer { try? handle?.close() }

        var differing: [String] = []
        for tap in taps {
            let record = try await Self.compare(tap, service: service, reference: reference)
            if let handle, let data = try? JSONEncoder().encode(record) {
                handle.write(data)
                handle.write(Data("\n".utf8))
            }
            if record.ours != record.expected {
                let key = { (entries: [Entry]) in entries.prefix(3).map { "\($0.expression)/\($0.reading)" } }
                differing.append("\(tap.source) \(tap.line) @\(tap.utf16Offset): ours \(key(record.ours)), Hachidori \(key(record.expected))")
            }
        }
        print("Parity: \(taps.count - differing.count) of \(taps.count) taps match Hachidori")
        // The full corpus is for the report; the committed sample must match outright.
        if corpus == nil {
            #expect(differing.isEmpty, "\(differing.prefix(20).joined(separator: "\n"))")
        }
    }

    /// One tap, both ways.
    static func compare(_ tap: Tap, service: LookupService, reference: Reference) async throws -> Record {
        let scanned = TextScanner.scanText(tap.line, utf16Offset: tap.utf16Offset)
        let ours = await service.lookup(text: tap.line, utf16Offset: tap.utf16Offset).results
        let text = hachidoriScan(tap.line, utf16Offset: tap.utf16Offset)
        let recorded: (page: [TermLookupResult], targets: [String: [TermLookupResult]]) =
            text.isEmpty ? ([], [:]) : try #require(reference[text], "no reference lookup of \(text)")
        let expected = NameRanking.forTextTap(Redirects.follow(recorded.page, found: recorded.targets))
        return Record(source: tap.source, line: tap.line, utf16Offset: tap.utf16Offset, scanned: scanned, hachidoriText: text,
                      ours: ours.map(Entry.init), hachidoriRaw: recorded.page.map(Entry.init), expected: expected.map(Entry.init))
    }

    /// The text Hachidori's popup looks up for a tap: from the tapped character to the end of the
    /// block, at most 256 code points (its widest scan window); the engine scans 16 of them.
    static func hachidoriScan(_ line: String, utf16Offset: Int) -> String {
        let utf16 = line.utf16
        guard utf16Offset < utf16.count, let start = utf16.index(utf16.startIndex, offsetBy: utf16Offset, limitedBy: utf16.endIndex),
              let index = start.samePosition(in: line) else { return "" }
        return String(line[index...].prefix { !$0.isNewline }.unicodeScalars.prefix(256).map(Character.init))
    }

    static func taps(_ file: URL) throws -> [Tap] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").compactMap { row in
            let parts = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 3, let offset = Int(parts[2]) else { return nil }
            return Tap(source: String(parts[0]), line: String(parts[1]), utf16Offset: offset)
        }
    }

    /// `scripts/parity-reference.mjs`' lines: `{text, page, redirects: {term: page}}`, pages as
    /// Hachidori's `hd_lookup` replies.
    static func reference(_ file: URL) throws -> Reference {
        var pages: Reference = [:]
        for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            guard let text = value["text"]?.string, let page = value["page"] else { continue }
            var targets: [String: [TermLookupResult]] = [:]
            if case let .object(redirects)? = value["redirects"] {
                for (term, result) in redirects { targets[term] = try HostLookupPage(response: result).results }
            }
            pages[text] = (try HostLookupPage(response: page).results, targets)
        }
        return pages
    }

    /// A lookup service over copies of a Hachidori host's dictionaries (`HACHIDORI_LINK_URL`), in
    /// its order and on/off, kept in `folder` between runs (`manifest.json` lists them for
    /// Hachidori's engine), following the host's frequency sorting as a linked app does.
    static func service(dictionaries folder: URL) async throws -> (LookupService, HostOptions) {
        let url = try #require(ProcessInfo.processInfo.environment["HACHIDORI_LINK_URL"].flatMap(HachidoriLink.linkURL),
                               "HACHIDORI_LINK_URL: the host whose dictionaries are compared")
        let link = HachidoriLink(url: url, clientName: "Amatsubame tests", clientVersion: "0.4.0")
        await link.start()
        _ = try await link.lookup("食べる")  // waits for the hello and its records
        let dictionaries = await link.records.dictionaries
        let options = await link.records.options
        await link.stop()

        let database = try AppDatabase.inMemory()
        let library = DictionaryLibrary(database: database,
                                        directory: FileManager.default.temporaryDirectory.appending(path: "parity-\(UUID().uuidString)"))
        let exports = HostDictionaryExports(baseURL: try #require(HostDictionaryExports.apiURL(forLink: url)))
        let exportable = Set(try await exports.list().map(\.id))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var order: [String] = []
        var manifest: [[String: Any]] = []
        for dictionary in dictionaries where exportable.contains(dictionary.id) {
            let copy = folder.appending(path: "\(dictionary.id)-\(dictionary.revision ?? "")")
            if !FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) {
                let zip = folder.appending(path: "\(dictionary.id).zip")
                try await exports.download(dictionary.id, to: zip)
                try HostDictionaryExports.unpack(zip, into: copy)
                try? FileManager.default.removeItem(at: zip)
            }
            manifest.append(["title": dictionary.title, "folder": copy.path(percentEncoded: false), "enabled": dictionary.enabled,
                             "terms": dictionary.termCount ?? 0, "frequencies": dictionary.frequencyCount ?? 0,
                             "pitches": dictionary.pitchCount ?? 0, "kanji": dictionary.kanjiCount ?? 0])
            // installCompiled moves the folder in: install a copy so the kept one stays.
            let installing = FileManager.default.temporaryDirectory.appending(path: "parity-copy-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: copy, to: installing)
            let kinds = DictionaryLibrary.CompiledKinds(terms: dictionary.termCount ?? 0, frequencies: dictionary.frequencyCount ?? 0,
                                                        pitches: dictionary.pitchCount ?? 0, kanji: dictionary.kanjiCount ?? 0,
                                                        media: dictionary.mediaCount ?? 0)
            let installed = try await library.installCompiled(installing, kinds: kinds)
            order.append(installed.dictionary.id)
            if !dictionary.enabled { try await library.setEnabled(installed.dictionary.id, false) }
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            .write(to: folder.deletingLastPathComponent().appending(path: "manifest.json"))
        try await library.reorder(order)
        try await library.setHostFrequencySort(.init(dictionary: options.frequencyDictionary, order: options.frequencyOrder))
        let service = LookupService(library: library, audio: AudioService(database: database))
        try await service.reload()
        return (service, options)
    }
}
