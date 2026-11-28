# Building from source

## Requirements

- iOS, iPadOS or macOS 26 (Hiku's extension runs in Safari on iPhone, iPad and Mac).
- Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- Your own servers for the apps you use: Kavita (Yomu), Jellyfin (Miru), Audiobookshelf 2.26.0 or later
  (Kiku and read-along), and optionally Kaku. For mining, Anki with
  [AnkiConnect](https://git.foosoft.net/alex/anki-connect) reachable from your devices. The
  Lapis note type has a built-in preset; other note types can be
  mapped field by field.

## Building

    brew install xcodegen
    xcodegen                  # generates Amatsubame.xcodeproj from project.yml
    open Amatsubame.xcodeproj

Pick a scheme (`Yomu`, `Miru`, `Kiku` or `Hiku`) and run it. Simulator builds need no signing. To run
on your own devices, create `Config/Signing.local.xcconfig` (gitignored) with your team and a
bundle ID prefix of your own (the default `com.amatsubame.*` IDs are registered to another team):

    DEVELOPMENT_TEAM = ABCDE12345
    BUNDLE_ID_PREFIX = com.yourname.amatsubame

Sharing the setup between the apps (an App Group) needs a paid Apple Developer Program team on devices;
without it each app keeps its own setup.

Nothing large is bundled. Yomu downloads the manga OCR models in Settings → Manga OCR, and setup
recommends Hachidori's default dictionaries (Jitendex, JMnedict, Bee's Ultimate Kanji, Jiten frequency,
Bee's Ultimate Grammar; Kanjium for pitch accent is optional) and installs them for
you; you can also import any Yomitan dictionary zip.
