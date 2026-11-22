#if os(macOS)
import AppKit
import Core
import Testing
@testable import AppCommon

/// Settings ▸ Popup ▸ Look Up on Hover: which keys let pointing at a word look it up.
@MainActor struct HoverLookupTests {
    @Test func theChosenKeyMustBeHeld() {
        #expect(!HoverModifiers.allows(.shift, held: []))
        #expect(HoverModifiers.allows(.shift, held: [.shift]))
        #expect(HoverModifiers.allows(.shift, held: [.shift, .command]), "other keys held as well don't matter")
        #expect(!HoverModifiers.allows(.option, held: [.shift]))
        #expect(HoverModifiers.allows(.option, held: [.option]))
        #expect(HoverModifiers.allows(.control, held: [.control]) && HoverModifiers.allows(.command, held: [.command]))
    }

    @Test func withoutAKeyPointingIsEnoughAndOffNeverLooksUp() {
        #expect(HoverModifiers.allows(.always, held: []))
        #expect(HoverModifiers.allows(.always, held: [.shift]))
        #expect(!HoverModifiers.allows(.off, held: [.shift, .option, .control, .command]))
    }

    @Test func shiftIsTheDefaultAndTheChoiceIsKept() throws {
        let store = LookupCountStore(database: try AppDatabase.inMemory())
        #expect(try store.settings().hoverLookup == .shift)
        var settings = try store.settings()
        settings.hoverLookup = .always
        try store.save(settings)
        #expect(try store.settings().hoverLookup == .always)
    }

    @Test func closingWhenThePointerLeavesIsOffUntilChosen() throws {
        let store = LookupCountStore(database: try AppDatabase.inMemory())
        #expect(try !store.settings().closeOnPointerExit)
        var settings = try store.settings()
        settings.closeOnPointerExit = true
        try store.save(settings)
        #expect(try store.settings().closeOnPointerExit)
    }
}
#endif
