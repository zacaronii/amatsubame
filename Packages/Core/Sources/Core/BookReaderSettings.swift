import Foundation
import GRDB

public struct BookReaderSettings: Codable, Equatable, Sendable {
    public enum Layout: String, Codable, CaseIterable, Sendable { case paged, scroll }
    public enum WritingMode: String, Codable, CaseIterable, Sendable {
        /// Whatever the book's own CSS says (most Japanese EPUBs are vertical).
        case auto, vertical, horizontal
    }
    public enum Theme: String, Codable, CaseIterable, Sendable { case system, light, sepia, dark }
    public enum Font: String, Codable, CaseIterable, Sendable { case book, mincho, gothic }
    /// When the percentage and characters read are shown.
    public enum ProgressText: String, Codable, CaseIterable, Sendable { case always, withControls, hidden }
    /// The book's furigana (ruby), or none.
    public enum Furigana: String, Codable, CaseIterable, Sendable { case book, hidden }

    public var layout: Layout = .paged
    public var writingMode: WritingMode = .auto
    /// Text size in points.
    public var fontSize: Double = 20
    public var lineHeight: Double = 1.7
    /// Page margin in points.
    public var margin: Double = 24
    public var theme: Theme = .system
    public var font: Font = .book
    public var progressText: ProgressText = .withControls
    /// A thin line along the bottom of the screen showing how far through the book you are.
    public var showsProgressBar = true
    public var furigana: Furigana = .book

    public init() {}

    enum CodingKeys: String, CodingKey {
        case layout, writingMode, fontSize, lineHeight, margin, theme, font, progressText, showsProgressBar, furigana
        /// Replaced by `progressText` (true meant always).
        case showsProgress
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layout, forKey: .layout)
        try container.encode(writingMode, forKey: .writingMode)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(lineHeight, forKey: .lineHeight)
        try container.encode(margin, forKey: .margin)
        try container.encode(theme, forKey: .theme)
        try container.encode(font, forKey: .font)
        try container.encode(progressText, forKey: .progressText)
        try container.encode(showsProgressBar, forKey: .showsProgressBar)
        try container.encode(furigana, forKey: .furigana)
    }

    /// Missing keys (settings saved by an older version) keep their defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = try container.decodeIfPresent(Layout.self, forKey: .layout) ?? layout
        writingMode = try container.decodeIfPresent(WritingMode.self, forKey: .writingMode) ?? writingMode
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        lineHeight = try container.decodeIfPresent(Double.self, forKey: .lineHeight) ?? lineHeight
        margin = try container.decodeIfPresent(Double.self, forKey: .margin) ?? margin
        theme = try container.decodeIfPresent(Theme.self, forKey: .theme) ?? theme
        font = try container.decodeIfPresent(Font.self, forKey: .font) ?? font
        if let text = try container.decodeIfPresent(ProgressText.self, forKey: .progressText) {
            progressText = text
        } else if let shows = try container.decodeIfPresent(Bool.self, forKey: .showsProgress) {
            progressText = shows ? .always : .hidden
        }
        showsProgressBar = try container.decodeIfPresent(Bool.self, forKey: .showsProgressBar) ?? showsProgressBar
        furigana = try container.decodeIfPresent(Furigana.self, forKey: .furigana) ?? furigana
    }

    public static let `default` = BookReaderSettings()
}

struct BookReaderSettingsRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "bookReaderSettings"
    var scope: String
    var settings: Data
}

/// Per-series book settings falling back to a global default.
public struct BookReaderSettingsStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    private static let globalScope = "global"
    private static func scope(seriesId: Int) -> String { "kavita.series.\(seriesId)" }

    public func settings(seriesId: Int) throws -> BookReaderSettings {
        try database.reader.read { db in
            for scope in [Self.scope(seriesId: seriesId), Self.globalScope] {
                if let row = try BookReaderSettingsRow.fetchOne(db, key: scope) {
                    return try JSONDecoder().decode(BookReaderSettings.self, from: row.settings)
                }
            }
            return .default
        }
    }

    public func save(_ settings: BookReaderSettings, seriesId: Int) throws {
        try save(settings, scope: Self.scope(seriesId: seriesId))
    }

    public func saveAsDefault(_ settings: BookReaderSettings) throws {
        try save(settings, scope: Self.globalScope)
    }

    private func save(_ settings: BookReaderSettings, scope: String) throws {
        let row = BookReaderSettingsRow(scope: scope, settings: try JSONEncoder().encode(settings))
        try database.writer.write { try row.save($0) }
    }
}

/// Kavita libraries the user turned off in Settings (all are shown by default).
public struct LibraryVisibilityStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func hiddenLibraryIds() throws -> Set<Int> {
        try database.reader.read { Set(try Int.fetchAll($0, sql: "SELECT libraryId FROM hiddenLibrary")) }
    }

    public func setHidden(_ libraryId: Int, hidden: Bool) throws {
        try database.writer.write { db in
            if hidden {
                try db.execute(sql: "INSERT OR IGNORE INTO hiddenLibrary (libraryId) VALUES (?)", arguments: [libraryId])
            } else {
                try db.execute(sql: "DELETE FROM hiddenLibrary WHERE libraryId = ?", arguments: [libraryId])
            }
        }
    }

    public func observeHidden() -> AsyncThrowingStream<Set<Int>, any Error> {
        database.values { Set(try Int.fetchAll($0, sql: "SELECT libraryId FROM hiddenLibrary")) }
    }
}
