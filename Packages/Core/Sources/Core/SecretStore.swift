import Foundation
import Security
import Synchronization

public struct SecretKey: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let kavitaAuthKey = SecretKey(rawValue: "kavita.authKey")
    public static let jellyfinAccessToken = SecretKey(rawValue: "jellyfin.accessToken")
    public static let jellyfinDeviceId = SecretKey(rawValue: "jellyfin.deviceId")
    public static let ankiAPIKey = SecretKey(rawValue: "anki.apiKey")
    public static let jimakuAPIKey = SecretKey(rawValue: "jimaku.apiKey")
    /// Audiobookshelf: the access token (or a pasted API key) and, after a sign-in, its refresh token.
    public static let audiobookshelfToken = SecretKey(rawValue: "audiobookshelf.token")
    public static let audiobookshelfRefreshToken = SecretKey(rawValue: "audiobookshelf.refreshToken")
    public static let kakuAPIToken = SecretKey(rawValue: "kaku.apiToken")
    /// Keys in word-audio source URLs, as JSON by placeholder id (`AudioSourceKeys` in Lookup).
    public static let audioSourceKeys = SecretKey(rawValue: "audioSource.keys")
}

/// Secrets (auth keys, tokens) live only here, never in SQLite or defaults.
public protocol SecretStore: Sendable {
    func secret(for key: SecretKey) throws -> String?
    func setSecret(_ value: String?, for key: SecretKey) throws
}

public struct KeychainError: Error, LocalizedError, Equatable {
    public let status: OSStatus
    public var errorDescription: String? {
        "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
    }
}

public struct KeychainSecretStore: SecretStore {
    public let service: String
    /// A Keychain access group shared with the other apps (the App Group's identifier), or
    /// nil for this app's own items.
    public let accessGroup: String?

    public init(service: String = Bundle.main.bundleIdentifier ?? "Amatsubame", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(_ key: SecretKey) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
            // macOS: the data-protection keychain, where access groups apply.
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    public func secret(for key: SecretKey) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        let query = baseQuery(key)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            // Background sync must be able to read tokens while the device is locked.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Deletes every item of this service.
    public func removeAll() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
            query[kSecUseDataProtectionKeychain as String] = true
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public final class InMemorySecretStore: SecretStore {
    private let storage = Mutex<[SecretKey: String]>([:])

    public init(_ initial: [SecretKey: String] = [:]) {
        storage.withLock { $0 = initial }
    }

    public func secret(for key: SecretKey) throws -> String? {
        storage.withLock { $0[key] }
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        storage.withLock { $0[key] = (value?.isEmpty ?? true) ? nil : value }
    }
}

/// Secrets that belong to the shared setup (the AnkiConnect key) go to `shared`, the rest to
/// `own`. Falls back to `own` when the shared store can't be used (no entitlement).
public struct RoutingSecretStore: SecretStore {
    public let own: any SecretStore
    public let shared: any SecretStore
    public static let sharedKeys: Set<SecretKey> = [.ankiAPIKey, .audioSourceKeys]

    public init(own: any SecretStore, shared: any SecretStore) {
        self.own = own
        self.shared = shared
    }

    public func secret(for key: SecretKey) throws -> String? {
        guard Self.sharedKeys.contains(key) else { return try own.secret(for: key) }
        do {
            return try shared.secret(for: key)
        } catch {
            return try own.secret(for: key)
        }
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        guard Self.sharedKeys.contains(key) else { return try own.setSecret(value, for: key) }
        do {
            try shared.setSecret(value, for: key)
        } catch {
            try own.setSecret(value, for: key)
        }
    }
}
