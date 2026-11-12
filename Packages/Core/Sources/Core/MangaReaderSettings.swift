import Foundation
import GRDB

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
    /// How many pages after the current one to OCR in advance.
    public var ocrAhead: Int = 3

    public init() {}

    enum CodingKeys: String, CodingKey {
        case mode, direction, spreads, coverAlone, stripWidth, showsTextBoxes, ocrAhead
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
