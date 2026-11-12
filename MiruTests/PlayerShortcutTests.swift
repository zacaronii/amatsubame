import Foundation
@testable import Miru
import SwiftUI
import Testing

@MainActor @Suite struct PlayerShortcutTests {
    private func match(_ characters: String, _ key: KeyEquivalent? = nil, _ modifiers: EventModifiers = []) -> PlayerShortcut? {
        PlayerShortcut.matching(characters: characters, key: key ?? KeyEquivalent(Character(characters)), modifiers: modifiers)
    }

    @Test func mpvKeys() {
        #expect(match(" ", .space) == .playPause)
        #expect(match("p") == .playPause)
        #expect(match("[") == .slower)
        #expect(match("]") == .faster)
        #expect(match(",") == .frameBack)
        #expect(match("l") == .loop)
        #expect(match("9") == .volumeDown)
        #expect(match("j") == .nextSubtitles)
        #expect(match("q") == .close)
        #expect(match("?") == .shortcuts)
    }

    /// `{`, `}`, `#`, `<`, `>` and `?` are typed with Shift: it picks the character, not a shortcut.
    @Test func shiftedCharactersIgnoreShift() {
        #expect(match("{", "[", .shift) == .halfSpeed)
        #expect(match("}", "]", .shift) == .doubleSpeed)
        #expect(match("#", "3", .shift) == .nextAudio)
        #expect(match(">", ".", .shift) == .nextEpisode)
        #expect(match("<", ",", .shift) == .previousEpisode)
        // iOS can report the unshifted character with Shift held.
        #expect(match("[", "[", .shift) == .halfSpeed)
        #expect(match("/", "/", .shift) == .shortcuts)
        #expect(match("3", "3", .shift) == .nextAudio)
        #expect(match("[") == .slower)
        // Caps Lock or Shift on a letter is still the letter.
        #expect(match("L", "l", .shift) == .loop)
    }

    /// Arrows: Shift and Control make different shortcuts; the Mac's arrow-key flags don't count.
    @Test func arrowModifiersMatter() {
        #expect(match("", .leftArrow) == .back5)
        #expect(match("", .leftArrow, [.numericPad, .function]) == .back5)
        #expect(match("", .leftArrow, .shift) == .back1)
        #expect(match("", .rightArrow, .control) == .nextLine)
        #expect(match("", .upArrow) == .previousLine)
        #expect(match("", .leftArrow, .option) == nil)
        #expect(match("", .delete) == .normalSpeed)
        #expect(match("\u{8}", KeyEquivalent("\u{8}")) == .normalSpeed)
    }

    @Test func commandKeysNeedCommand() {
        #expect(match("f", "f", .command) == .search)
        #expect(match("e", "e", .command) == .english)
        #expect(match("e") == .english)
        #expect(match("w", "w", .command) == nil)
    }

    /// Every key belongs to one shortcut, so the menu and the cheat sheet never disagree.
    @Test func noKeyIsUsedTwice() {
        var seen: [String: PlayerShortcut] = [:]
        for shortcut in PlayerShortcut.allCases {
            for key in shortcut.keys {
                let id = "\(key.key.character)/\(key.modifiers.rawValue)"
                #expect(seen[id] == nil, "\(key.label) is used by \(seen[id]?.rawValue ?? "") and \(shortcut.rawValue)")
                seen[id] = shortcut
            }
        }
    }

    #if os(macOS)
    @Test func fullScreenIsOnTheMac() {
        #expect(match("f") == .fullScreen)
    }
    #else
    @Test func noFullScreenOnIPhoneAndIPad() {
        #expect(match("f") == nil)
        #expect(!PlayerShortcut.available.contains(.fullScreen))
    }
    #endif
}
