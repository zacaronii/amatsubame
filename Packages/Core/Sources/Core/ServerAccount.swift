import Foundation
import GRDB

public enum ServerKind: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case kavita, jellyfin, anki
    /// Kiku: podcasts and audiobooks, and the Kaku transcriber beside it.
    case audiobookshelf, kaku
}

/// Non-secret connection details for one server. Secrets live in `SecretStore`.
public struct ServerAccount: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var kind: ServerKind
    public var baseURL: URL
    public var username: String?
    public var userId: String?
    public var serverName: String?
    public var serverVersion: String?
    public var lastCheckedAt: Date?

    public init(
        kind: ServerKind,
        baseURL: URL,
        username: String? = nil,
        userId: String? = nil,
        serverName: String? = nil,
        serverVersion: String? = nil,
        lastCheckedAt: Date? = nil
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.username = username
        self.userId = userId
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.lastCheckedAt = lastCheckedAt
    }
}

public struct AccountStore: Sendable {
    public let database: AppDatabase
    /// The shared setup's database, when the app shares its setup: the AnkiConnect account
    /// (`SharedSetup.sharedServerKinds`) lives there instead.
    public let shared: AppDatabase?

    public init(database: AppDatabase, shared: AppDatabase? = nil) {
        self.database = database
        self.shared = shared
    }

    private func database(for kind: ServerKind) -> AppDatabase {
        SharedSetup.sharedServerKinds.contains(kind) ? (shared ?? database) : database
    }

    public func account(_ kind: ServerKind) throws -> ServerAccount? {
        try database(for: kind).reader.read { try ServerAccount.fetchOne($0, key: kind.rawValue) }
    }

    public func save(_ account: ServerAccount) throws {
        try database(for: account.kind).writer.write { try account.save($0) }
    }

    public func delete(_ kind: ServerKind) throws {
        _ = try database(for: kind).writer.write { try ServerAccount.deleteOne($0, key: kind.rawValue) }
    }

    /// The app's own accounts (without the shared kinds when sharing); see `observeShared`.
    public func observeAll() -> AsyncThrowingStream<[ServerKind: ServerAccount], any Error> {
        let excluded = shared == nil ? [] : SharedSetup.sharedServerKinds.map(\.rawValue)
        return database.values { db in
            Dictionary(uniqueKeysWithValues: try ServerAccount.fetchAll(db).filter { !excluded.contains($0.kind.rawValue) }.map { ($0.kind, $0) })
        }
    }

    /// The shared accounts (AnkiConnect), when sharing; empty otherwise.
    public func observeShared() -> AsyncThrowingStream<[ServerKind: ServerAccount], any Error> {
        guard let shared else { return AsyncThrowingStream { $0.yield([:]); $0.finish() } }
        let kinds = SharedSetup.sharedServerKinds.map(\.rawValue)
        return shared.values { db in
            Dictionary(uniqueKeysWithValues: try ServerAccount.fetchAll(db).filter { kinds.contains($0.kind.rawValue) }.map { ($0.kind, $0) })
        }
    }
}
