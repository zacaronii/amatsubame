import Foundation

/// Builds small Yomitan (format 3) dictionary zips for tests.
public struct TestDictionaryBuilder {
    public struct Term {
        public var expression: String
        public var reading: String
        public var rules: String
        public var glossary: [Any]
        public var definitionTags: String
        public var score: Int

        public init(_ expression: String, _ reading: String, rules: String = "", glossary: [Any] = ["test"],
                    definitionTags: String = "", score: Int = 0) {
            self.expression = expression
            self.reading = reading
            self.rules = rules
            self.glossary = glossary
            self.definitionTags = definitionTags
            self.score = score
        }
    }

    public var title: String
    public var revision: String
    public var terms: [Term] = []
    /// (term, reading, value, display)
    public var frequencies: [(String, String?, Int, String?)] = []
    /// (term, reading, downsteps)
    public var pitches: [(String, String, [Int])] = []
    public var media: [String: Data] = [:]
    public var styles: String?
    /// More `index.json` fields (e.g. `isUpdatable`, `indexUrl`, `downloadUrl`).
    public var index: [String: Any] = [:]

    public init(title: String, revision: String = "1") {
        self.title = title
        self.revision = revision
    }

    public func zipData() throws -> Data {
        var zip = ZipWriter()
        try zip.add("index.json", json: index.merging(["title": title, "revision": revision, "format": 3, "sequenced": false]) { $1 })
        if !terms.isEmpty {
            try zip.add("term_bank_1.json", json: terms.enumerated().map { index, term in
                [term.expression, term.reading, term.definitionTags, term.rules, term.score, term.glossary, index + 1, ""] as [Any]
            })
        }
        var meta: [[Any]] = frequencies.map { term, reading, value, display in
            var frequency: [String: Any] = ["value": value]
            if let display { frequency["displayValue"] = display }
            if let reading { return [term, "freq", ["reading": reading, "frequency": frequency]] }
            return [term, "freq", frequency]
        }
        meta += pitches.map { term, reading, downsteps in
            [term, "pitch", ["reading": reading, "pitches": downsteps.map { ["position": $0] }]]
        }
        if !meta.isEmpty { try zip.add("term_meta_bank_1.json", json: meta) }
        for (path, data) in media { zip.add(path, data) }
        if let styles { zip.add("styles.css", Data(styles.utf8)) }
        return zip.data()
    }

    /// Writes the zip to a new temporary file and returns its URL.
    public func write(to directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = directory.appending(path: "\(UUID().uuidString).zip")
        try zipData().write(to: url)
        return url
    }
}
