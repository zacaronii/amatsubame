# Amatsubame (アマツバメ)

Japanese immersion apps for your own self-hosted media. Read manga and light novels from
[Kavita](https://www.kavitareader.com), watch anime and shows from [Jellyfin](https://jellyfin.org),
listen to podcasts and audiobooks from [Audiobookshelf](https://www.audiobookshelf.org), and look
words up in Safari. Every app shares one Yomitan-style dictionary lookup (Yomitan-format
dictionaries, deinflection, frequency, pitch accent and word audio) and mines cards to Anki through
AnkiConnect. Progress syncs back to your servers, and downloads and mined cards keep working offline.

The amatsubame (Pacific swift) almost never lands: it eats, drinks and sleeps in flight. That's the
idea: never touching down out of Japanese.

| App | | What it does |
| --- | --- | --- |
| **Yomu** | 読む, to read | Manga and EPUBs from Kavita: on-device manga OCR (tap a speech bubble to look a word up), vertical or horizontal EPUBs, and read-along with a paired Audiobookshelf audiobook |
| **Miru** | 見る, to watch | Jellyfin video through mpv with tappable Japanese subtitles, subtitles from Jimaku with Auto-Sync, and Lines: a searchable history of the lines you've watched |
| **Kiku** | 聞く, to listen | Audiobookshelf podcasts and audiobooks with tappable transcripts from Kaku, plus marks: mark what you just heard (AirPods, Action Button, Siri) and mine it later |
| **Hiku** | 引く, to look up | A Safari Web Extension: tap Japanese text on any page for the same popup, and mine it to Anki |
| **Kaku** | 書く, to write down | A transcription server (Whisper large-v3 on an NVIDIA GPU) that writes timed Japanese transcripts of your Audiobookshelf libraries for Kiku and Yomu, and subtitles for Jellyfin episodes on request |

The apps share dictionaries, word audio sources and AnkiConnect settings on a device, so you set them
up once.

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
on your own devices, create `Config/Signing.local.xcconfig` (gitignored) with your team:

    DEVELOPMENT_TEAM = ABCDE12345

Sharing the setup between the apps (an App Group) needs a paid Apple Developer Program team on devices;
without it each app keeps its own setup.

Nothing large is bundled. Yomu downloads the manga OCR models in Settings → Manga OCR, and setup
recommends dictionaries (Jitendex, JMnedict, KANJIDIC, Jiten frequency, Kanjium) and installs them for
you; you can also import any Yomitan dictionary zip.

## Kaku

Kaku lives in [`Server/kaku`](Server/kaku): a Docker container for a machine with an NVIDIA GPU. See
its [README](Server/kaku/README.md) to run it and [docs/kaku.md](docs/kaku.md) for its API.

## Documentation

User documentation is at [amatsubame.com](https://amatsubame.com). Developer notes are in
[`docs/`](docs): one file per app ([yomu](docs/yomu.md), [miru](docs/miru.md), [kiku](docs/kiku.md),
[hiku](docs/hiku.md), [kaku](docs/kaku.md)), the shared pieces ([shared.md](docs/shared.md)), and the
original plans ([PLAN.md](docs/PLAN.md), [AUDIO_PLAN.md](docs/AUDIO_PLAN.md),
[NAMING.md](docs/NAMING.md)). [CLAUDE.md](CLAUDE.md) holds the project's rules and commands for
contributors and coding agents.

## Acknowledgements

Amatsubame stands on the work of many people. Thank you to:

**Built on and inspired by**
- [hoshidicts](https://github.com/Manhhao/hoshidicts) by Manhhao: the dictionary engine behind every
  lookup. Manhhao's Hoshi Reader was an inspiration too.
- [Yomitan](https://github.com/yomidevs/yomitan): its dictionary format, deinflection rules and popup
  design shaped how lookup works here.
- [Jiten](https://jiten.moe): its underlines on known words inspired the word marks in every app.
- [nemu-ocr-coreml](https://huggingface.co/nemu-pm/nemu-ocr-coreml): the manga text detection and
  recognition models.
- [mpv](https://mpv.io), [FFmpeg](https://ffmpeg.org) and [MPVKit](https://github.com/mpvkit/MPVKit):
  video playback in Miru.
- [faster-whisper](https://github.com/SYSTRAN/faster-whisper) and OpenAI's
  [Whisper](https://github.com/openai/whisper): Kaku's transcripts.
- [GRDB.swift](https://github.com/groue/GRDB.swift), [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)
  and [libfvad](https://github.com/dpirch/libfvad), along with the libraries listed in
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

**Works with**
- [Kavita](https://www.kavitareader.com), [Jellyfin](https://jellyfin.org) and
  [Audiobookshelf](https://www.audiobookshelf.org), the self-hosted servers the apps read from.
- [AnkiConnect](https://ankiweb.net/shared/info/2055492159) and the
  [Lapis](https://github.com/donkuri/lapis) note type, for mining cards.
- [Jimaku](https://jimaku.cc) for Japanese subtitles, and
  [kechimochi](https://github.com/Morgawr/kechimochi) for immersion tracking.

## License

The apps are licensed under the [GNU General Public License v3.0](LICENSE): they link the GPL-3.0
dictionary engine [hoshidicts](https://github.com/Manhhao/hoshidicts). Kaku is a separate program under
the [MIT License](Server/kaku/LICENSE). Third-party components and their licenses are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The apps aren't distributed through the App Store: Apple's terms add restrictions the GPL doesn't
allow. Build them from source.
