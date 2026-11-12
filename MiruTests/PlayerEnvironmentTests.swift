import AppCommon
import Core
import Foundation
@testable import Miru
import Testing

@MainActor @Suite struct PlayerEnvironmentTests {
    @Test func startsEmptyInMemory() throws {
        let environment = PlayerEnvironment.preview()
        #expect(try environment.common.outbox.summary() == .empty)
        #expect(environment.common.serverAccounts.isEmpty)
        #expect(environment.common.startupError == nil)
    }
}
