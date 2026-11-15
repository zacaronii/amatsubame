import Foundation
import GRDB

/// Settings ▸ Hachidori: a Hachidori host to look words up on (docs/hachidori.md). Shared by the
/// apps like the dictionaries. The host has no login, so it's only ever reached over the LAN or
/// a private network such as Tailscale.
public struct HachidoriSettings: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "hachidoriSettings"

    public var id = 1
    public var enabled: Bool
    /// What the user typed: a host, host:port or a `ws://…/link` URL.
    public var address: String

    public init(enabled: Bool = false, address: String = "") {
        self.enabled = enabled
        self.address = address
    }
}

extension AppDatabase {
    public func hachidoriSettings() throws -> HachidoriSettings {
        try reader.read { try HachidoriSettings.fetchOne($0, key: 1) } ?? HachidoriSettings()
    }

    public func saveHachidoriSettings(_ settings: HachidoriSettings) throws {
        try writer.write { try settings.save($0) }
    }
}
