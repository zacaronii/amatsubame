@testable import AppCommon
import Foundation
import Testing

@MainActor @Suite struct SetupProgressTests {
    func progress() -> (SetupProgress, UserDefaults) {
        let defaults = UserDefaults(suiteName: "setup-tests-\(UUID().uuidString)")!
        return (SetupProgress(defaults: defaults), defaults)
    }

    @Test func aFirstLaunchShowsSetupAndResumesWhereItWasLeft() {
        let (setup, defaults) = progress()
        #expect(setup.showsSetup)
        setup.reached("anki")
        let again = SetupProgress(defaults: defaults)
        #expect(again.showsSetup && again.step == "anki")
        again.finish()
        #expect(!SetupProgress(defaults: defaults).showsSetup)
    }

    @Test func anExistingInstallNeverSeesSetup() {
        let (setup, _) = progress()
        setup.noteExistingSetup(hasServer: false)
        #expect(setup.showsSetup, "no server yet: setup shows")
        setup.noteExistingSetup(hasServer: true)
        #expect(!setup.showsSetup)
    }

    @Test func runSetupAgainIsntUndoneAtTheNextLaunch() {
        let (setup, defaults) = progress()
        setup.finish()
        setup.runAgain()
        #expect(setup.showsSetup && setup.isRerun)
        // The next launch: the server is connected, but setup was asked for.
        let next = SetupProgress(defaults: defaults)
        next.noteExistingSetup(hasServer: true)
        #expect(next.showsSetup)
    }

    @Test func skippingStaysSkipped() {
        let (setup, defaults) = progress()
        setup.skip()
        let next = SetupProgress(defaults: defaults)
        next.noteExistingSetup(hasServer: false)
        #expect(!next.showsSetup)
    }

    @Test func librariesAreGuessedFromTheirNames() {
        for name in ["マンガ", "ライトノベル", "アニメ", "日本語", "Japanese Films", "Anime JP", "JPN Dramas"] {
            #expect(LibraryGuess.isJapanese(name), "\(name)")
        }
        for name in ["Books", "Comics", "Shows", "Movies", "Audiobooks", "Jpeg Scans"] {
            #expect(!LibraryGuess.isJapanese(name), "\(name)")
        }
    }
}
