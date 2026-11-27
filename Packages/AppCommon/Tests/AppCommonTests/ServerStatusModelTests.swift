@testable import AppCommon
import Foundation
import Testing

/// The Settings status card's checks: a server that couldn't be reached is checked again as soon
/// as anything asks (the network came back), while one that answered isn't asked again for a minute.
@MainActor @Suite struct ServerStatusModelTests {
    struct Unreachable: LocalizedError {
        var errorDescription: String? { "The server can't be reached." }
    }

    /// A check that fails while `reachable` is false, counting its calls.
    @MainActor final class Server {
        var reachable: Bool
        var checks = 0
        init(reachable: Bool) { self.reachable = reachable }

        func item(_ name: String) -> StatusItem {
            StatusItem(name, isSetUp: true) { [self] in
                checks += 1
                if !reachable { throw Unreachable() }
            }
        }
    }

    @Test func aFailureIsCheckedAgainOnTheNextRefresh() async {
        let model = ServerStatusModel()
        let anki = Server(reachable: false)
        await model.refresh([anki.item("Anki")])
        #expect(model.states["Anki"] == .failed("The server can't be reached."))
        // Back on the network: the next refresh (not forced) asks again and the chip turns green.
        anki.reachable = true
        await model.refresh([anki.item("Anki")])
        #expect(anki.checks == 2)
        #expect(model.states["Anki"] == .ok)
    }

    @Test func aSuccessIsKeptForAMinute() async {
        let model = ServerStatusModel()
        let kaku = Server(reachable: true)
        await model.refresh([kaku.item("Kaku")])
        await model.refresh([kaku.item("Kaku")])
        #expect(kaku.checks == 1)
        await model.refresh([kaku.item("Kaku")], force: true)
        #expect(kaku.checks == 2)
    }

    @Test func recheckingFailuresLeavesTheOthersAlone() async {
        let model = ServerStatusModel()
        let anki = Server(reachable: false), kaku = Server(reachable: true)
        let items = [anki.item("Anki"), kaku.item("Kaku")]
        await model.refresh(items)
        anki.reachable = true
        await model.recheckFailed(items)
        #expect(anki.checks == 2)
        #expect(kaku.checks == 1)
        #expect(model.hasFailures == false)
    }
}
