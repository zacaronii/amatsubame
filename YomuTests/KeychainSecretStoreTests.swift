import Core
import Foundation
import Testing

/// Runs inside the app host so the Keychain is available.
@Suite struct KeychainSecretStoreTests {
    let store = KeychainSecretStore(service: "amatsubame.tests.\(UUID().uuidString)")

    @Test func roundTripsUpdatesAndDeletes() throws {
        #expect(try store.secret(for: .kavitaAuthKey) == nil)
        try store.setSecret("first", for: .kavitaAuthKey)
        #expect(try store.secret(for: .kavitaAuthKey) == "first")
        try store.setSecret("second", for: .kavitaAuthKey)
        #expect(try store.secret(for: .kavitaAuthKey) == "second")
        try store.setSecret(nil, for: .kavitaAuthKey)
        #expect(try store.secret(for: .kavitaAuthKey) == nil)
    }

    @Test func keysAreIndependent() throws {
        defer {
            try? store.setSecret(nil, for: .jellyfinAccessToken)
            try? store.setSecret(nil, for: .ankiAPIKey)
        }
        try store.setSecret("token", for: .jellyfinAccessToken)
        try store.setSecret("anki", for: .ankiAPIKey)
        #expect(try store.secret(for: .jellyfinAccessToken) == "token")
        #expect(try store.secret(for: .ankiAPIKey) == "anki")
    }
}
