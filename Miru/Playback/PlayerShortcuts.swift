import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The player's keyboard shortcuts: mpv's where they fit, plus the app's own for lines and
/// lookups. This one list drives the keys, the Playback menu and the cheat sheet
/// (Settings → Keyboard Shortcuts, and `?` over the video), so they can't drift apart.
enum PlayerShortcut: String, CaseIterable, Identifiable {
    case playPause, back5, forward5, back1, forward1
    case previousLine, nextLine, replayLine, lineBefore, lookUpLine, search
    case slower, faster, halfSpeed, doubleSpeed, normalSpeed, frameBack, frameForward, loop
    case volumeDown, volumeUp, mute, nextAudio
    case toggleJapanese, nextSubtitles, subtitlesEarlier, subtitlesLater, english
    case skip, previousEpisode, nextEpisode
    case info, fullScreen, shortcuts, close

    var id: String { rawValue }

    struct Key: Equatable {
        let key: KeyEquivalent
        let modifiers: EventModifiers
        /// How the cheat sheet shows it.
        let label: String

        init(_ key: KeyEquivalent, _ modifiers: EventModifiers = [], _ label: String) {
            self.key = key
            self.modifiers = modifiers
            self.label = label
        }

        static func == (a: Key, b: Key) -> Bool { a.key.character == b.key.character && a.modifiers == b.modifiers }
    }

    enum Section: String, CaseIterable, Identifiable {
        case playback = "Playback", lines = "Lines and Lookup", speed = "Speed and Frames", sound = "Sound"
        case subtitles = "Subtitles", episodes = "Episodes", window = "Window"
        var id: String { rawValue }
    }

    var keys: [Key] {
        switch self {
        case .playPause: [Key(.space, [], "Space"), Key("p", [], "P")]
        case .back5: [Key(.leftArrow, [], "←")]
        case .forward5: [Key(.rightArrow, [], "→")]
        case .back1: [Key(.leftArrow, .shift, "⇧←")]
        case .forward1: [Key(.rightArrow, .shift, "⇧→")]
        case .previousLine: [Key(.upArrow, [], "↑"), Key(.leftArrow, .control, "⌃←")]
        case .nextLine: [Key(.downArrow, [], "↓"), Key(.rightArrow, .control, "⌃→")]
        case .replayLine: [Key("r", [], "R")]
        case .lineBefore: [Key("b", [], "B")]
        case .lookUpLine: [Key("a", [], "A")]
        case .search: [Key("f", .command, "⌘F")]
        case .slower: [Key("[", [], "[")]
        case .faster: [Key("]", [], "]")]
        case .halfSpeed: [Key("{", [], "{")]
        case .doubleSpeed: [Key("}", [], "}")]
        case .normalSpeed: [Key(.delete, [], "⌫")]
        case .frameBack: [Key(",", [], ",")]
        case .frameForward: [Key(".", [], ".")]
        case .loop: [Key("l", [], "L")]
        case .volumeDown: [Key("9", [], "9")]
        case .volumeUp: [Key("0", [], "0")]
        case .mute: [Key("m", [], "M")]
        case .nextAudio: [Key("#", [], "#")]
        case .toggleJapanese: [Key("v", [], "V")]
        case .nextSubtitles: [Key("j", [], "J")]
        case .subtitlesEarlier: [Key("z", [], "Z")]
        case .subtitlesLater: [Key("x", [], "X")]
        case .english: [Key("e", [], "E"), Key("e", .command, "⌘E")]
        case .skip: [Key("s", [], "S")]
        case .previousEpisode: [Key("<", [], "<")]
        case .nextEpisode: [Key(">", [], ">")]
        case .info: [Key("i", [], "I")]
        case .fullScreen: [Key("f", [], "F")]
        case .shortcuts: [Key("?", [], "?")]
        case .close: [Key("q", [], "Q"), Key(.escape, [], "Esc")]
        }
    }

    var title: String {
        switch self {
        case .playPause: "Play or Pause"
        case .back5: "Back 5 Seconds"
        case .forward5: "Forward 5 Seconds"
        case .back1: "Back 1 Second"
        case .forward1: "Forward 1 Second"
        case .previousLine: "Previous Line"
        case .nextLine: "Next Line"
        case .replayLine: "Replay Line"
        case .lineBefore: "Line Before"
        case .lookUpLine: "Look Up the Line"
        case .search: "Search the Dictionary…"
        case .slower: "Slower"
        case .faster: "Faster"
        case .halfSpeed: "Half Speed"
        case .doubleSpeed: "Double Speed"
        case .normalSpeed: "Normal Speed"
        case .frameBack: "Frame Back"
        case .frameForward: "Frame Forward"
        case .loop: "Loop: Set Start, End, Off"
        case .volumeDown: "Volume Down"
        case .volumeUp: "Volume Up"
        case .mute: "Mute"
        case .nextAudio: "Next Audio Track"
        case .toggleJapanese: "Hide or Show Japanese Subtitles"
        case .nextSubtitles: "Next Japanese Subtitle Track"
        case .subtitlesEarlier: "Subtitles 0.1 s Earlier"
        case .subtitlesLater: "Subtitles 0.1 s Later"
        case .english: "English Subtitles"
        case .skip: "Skip Intro or Credits"
        case .previousEpisode: "Previous Episode"
        case .nextEpisode: "Next Episode"
        case .info: "Stream Info"
        case .fullScreen: "Full Screen"
        case .shortcuts: "Keyboard Shortcuts"
        case .close: "Close Video"
        }
    }

    /// What the cheat sheet adds under the title, where the name isn't enough.
    var detail: String? {
        switch self {
        case .previousLine: "Within a line's first second, the line before; later, the start of this one."
        case .lineBefore: "Always the line before the one on screen (like the AirPods triple press)."
        case .lookUpLine: "Pauses and opens the dictionary at the line's first word."
        case .slower, .faster: "10% at a time."
        case .frameBack, .frameForward: "Pauses."
        case .loop: "Press once at the start, again at the end; a third press stops looping."
        case .nextSubtitles: "Jellyfin's Japanese tracks and the file picked on Jimaku."
        case .subtitlesEarlier, .subtitlesLater: "A Jimaku file keeps its timing; Jellyfin's tracks only for this episode."
        case .fullScreen: "Double-clicking the video also works."
        case .close: "Esc closes the lookup or leaves full screen first."
        default: nil
        }
    }

    var section: Section {
        switch self {
        case .playPause, .back5, .forward5, .back1, .forward1: .playback
        case .previousLine, .nextLine, .replayLine, .lineBefore, .lookUpLine, .search: .lines
        case .slower, .faster, .halfSpeed, .doubleSpeed, .normalSpeed, .frameBack, .frameForward, .loop: .speed
        case .volumeDown, .volumeUp, .mute, .nextAudio: .sound
        case .toggleJapanese, .nextSubtitles, .subtitlesEarlier, .subtitlesLater, .english: .subtitles
        case .skip, .previousEpisode, .nextEpisode: .episodes
        case .info, .fullScreen, .shortcuts, .close: .window
        }
    }

    /// Full screen is the Mac's (the iPhone and iPad player is always full screen).
    static var available: [PlayerShortcut] {
        #if os(macOS)
        allCases
        #else
        allCases.filter { $0 != .fullScreen }
        #endif
    }

    /// The menu shows (and AppKit matches) the first key; the others work from the video.
    var menuShortcut: KeyboardShortcut? {
        guard let first = keys.first, first.key != .escape else { return nil }
        return KeyboardShortcut(first.key, modifiers: first.modifiers)
    }

    /// Keys whose modifiers matter exactly (Shift-arrow is its own shortcut). For typed
    /// characters Shift only picks the character ({ is Shift-[), so it's ignored, once the
    /// character is the shifted one: iOS can report Shift-[ as "[" with Shift held.
    private static let namedKeys: [Character] = [KeyEquivalent.space, .leftArrow, .rightArrow, .upArrow, .downArrow, .delete, .escape]
        .map(\.character)

    private static let shifted: [String: String] = ["[": "{", "]": "}", "3": "#", ",": "<", ".": ">", "/": "?"]

    /// The shortcut for a key press: `characters` is what was typed, `key` the key.
    static func matching(characters: String, key: KeyEquivalent, modifiers: EventModifiers) -> PlayerShortcut? {
        let relevant: EventModifiers = [.shift, .control, .option, .command]
        let held = modifiers.intersection(relevant)
        let characters = held.contains(.shift) ? shifted[characters] ?? characters : characters
        // Backspace is DEL on the Mac and BS (U+0008) on iOS.
        let key = key.character == "\u{8}" || characters == "\u{8}" ? KeyEquivalent.delete : key
        for shortcut in available {
            for candidate in shortcut.keys {
                if namedKeys.contains(candidate.key.character) {
                    if key.character == candidate.key.character && held == candidate.modifiers { return shortcut }
                } else if characters.lowercased() == String(candidate.key.character)
                            && held.subtracting(.shift) == candidate.modifiers {
                    return shortcut
                }
            }
        }
        return nil
    }
}

/// The Mac window the player is in (full screen with F or a double-click).
enum PlayerWindow {
    static var isFullScreen: Bool {
        #if os(macOS)
        NSApp.keyWindow?.styleMask.contains(.fullScreen) == true
        #else
        false
        #endif
    }

    static func toggleFullScreen() {
        #if os(macOS)
        NSApp.keyWindow?.toggleFullScreen(nil)
        #endif
    }
}

/// The cheat sheet: in Settings, and over the video with `?`.
struct PlayerShortcutsList: View {
    var body: some View {
        ForEach(PlayerShortcut.Section.allCases) { section in
            Section(section.rawValue) {
                ForEach(PlayerShortcut.available.filter { $0.section == section }) { shortcut in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shortcut.title)
                            if let detail = shortcut.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(shortcut.keys, id: \.label) { key in
                                Text(key.label)
                                    .font(.body.monospaced())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: .rect(cornerRadius: 5))
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("shortcut.\(shortcut.rawValue)")
                }
            }
        }
    }
}

/// Settings → Keyboard Shortcuts.
struct PlayerShortcutsView: View {
    var body: some View {
        Form {
            Section {
                Text("These work while a video is playing, with the Mac's keyboard or one attached to the iPad. Most are mpv's.")
                    .foregroundStyle(.secondary)
            }
            PlayerShortcutsList()
        }
        .formStyle(.grouped)
        .navigationTitle("Keyboard Shortcuts")
    }
}
