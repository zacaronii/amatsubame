import Foundation
import GRDB

/// What a tap on the left and right of a page does in the readers.
public enum ReaderTapZones: String, Codable, CaseIterable, Sendable {
    /// Toward the next page on the side the book reads to (the left, in a right-to-left book).
    case standard
    /// The sides swapped (for the other hand).
    case inverted
    /// Taps never turn pages (swipe instead): they only look words up and show the controls.
    case off
}

public struct MangaReaderSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable { case paged, longStrip }
    public enum Direction: String, Codable, CaseIterable, Sendable { case rightToLeft, leftToRight }
    public enum Spreads: String, Codable, CaseIterable, Sendable { case auto, on, off }

    public var mode: Mode = .paged
    public var direction: Direction = .rightToLeft
    public var spreads: Spreads = .auto
    /// Show the first page alone so spreads pair the way the printed book does.
    public var coverAlone: Bool = true
    /// Long-strip page width as a fraction of the screen width (0.6–1).
    public var stripWidth: Double = 1
    /// Outline detected text blocks on the page.
    public var showsTextBoxes: Bool = false
    /// While a word is looked up, the bubble's recognized text is typeset over it, so the next
    /// tap lands on an exact character.
    public var showsTextOverlay: Bool = true
    public var tapZones: ReaderTapZones = .standard
    /// A double tap zooms into the page (and back). Off by default: with it on, a single tap
    /// waits a moment to see whether a second follows.
    public var doubleTapZooms: Bool = false
    /// How many pages after the current one to OCR in advance.
    public var ocrAhead: Int = 3
    /// In a portrait reader, a two-page scan (Kavita's wide page) is shown one half at a time.
    public var splitsWidePages: Bool = true
    /// The paged reader trims a page's blank margins (white or black) off the screen.
    public var cropsBorders: Bool = false
    /// Auto-scroll's speed in the long strip, 1 (slow) to 10.
    public var autoScrollLevel: Int = 5

    public init() {}

    enum CodingKeys: String, CodingKey {
        case mode, direction, spreads, coverAlone, stripWidth, showsTextBoxes, ocrAhead, showsTextOverlay, tapZones, doubleTapZooms, splitsWidePages, autoScrollLevel, cropsBorders
    }

    /// Missing keys (settings saved by an older version) keep their defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? mode
        direction = try container.decodeIfPresent(Direction.self, forKey: .direction) ?? direction
        spreads = try container.decodeIfPresent(Spreads.self, forKey: .spreads) ?? spreads
        coverAlone = try container.decodeIfPresent(Bool.self, forKey: .coverAlone) ?? coverAlone
        stripWidth = try container.decodeIfPresent(Double.self, forKey: .stripWidth) ?? stripWidth
        showsTextBoxes = try container.decodeIfPresent(Bool.self, forKey: .showsTextBoxes) ?? showsTextBoxes
        showsTextOverlay = try container.decodeIfPresent(Bool.self, forKey: .showsTextOverlay) ?? showsTextOverlay
        tapZones = try container.decodeIfPresent(ReaderTapZones.self, forKey: .tapZones) ?? tapZones
        doubleTapZooms = try container.decodeIfPresent(Bool.self, forKey: .doubleTapZooms) ?? doubleTapZooms
        splitsWidePages = try container.decodeIfPresent(Bool.self, forKey: .splitsWidePages) ?? splitsWidePages
        autoScrollLevel = try container.decodeIfPresent(Int.self, forKey: .autoScrollLevel) ?? autoScrollLevel
        cropsBorders = try container.decodeIfPresent(Bool.self, forKey: .cropsBorders) ?? cropsBorders
        ocrAhead = try container.decodeIfPresent(Int.self, forKey: .ocrAhead) ?? ocrAhead
    }

    public static let `default` = MangaReaderSettings()
}

struct MangaReaderSettingsRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mangaReaderSettings"
    var scope: String
    var settings: Data
}

/// Per-series reader settings falling back to a global default.
public struct MangaReaderSettingsStore: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    private static let globalScope = "global"
    private static func scope(seriesId: Int) -> String { "kavita.series.\(seriesId)" }

    public func settings(seriesId: Int) throws -> MangaReaderSettings {
        try database.reader.read { db in
            for scope in [Self.scope(seriesId: seriesId), Self.globalScope] {
                if let row = try MangaReaderSettingsRow.fetchOne(db, key: scope) {
                    return try JSONDecoder().decode(MangaReaderSettings.self, from: row.settings)
                }
            }
            return .default
        }
    }

    public func save(_ settings: MangaReaderSettings, seriesId: Int) throws {
        try save(settings, scope: Self.scope(seriesId: seriesId))
    }

    /// Makes these settings the default for series without their own.
    public func saveAsDefault(_ settings: MangaReaderSettings) throws {
        try save(settings, scope: Self.globalScope)
    }

    private func save(_ settings: MangaReaderSettings, scope: String) throws {
        let row = MangaReaderSettingsRow(scope: scope, settings: try JSONEncoder().encode(settings))
        try database.writer.write { try row.save($0) }
    }
}
