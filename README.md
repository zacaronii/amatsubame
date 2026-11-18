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
| **Kiku** | 聞く, to listen | Audiobookshelf podcasts and audiobooks with tappable transcripts from Kaku, plus marks: mark what you just heard (AirPods, Action Button, Siri, CarPlay, Apple Watch) and mine it later |
| **Hiku** | 引く, to look up | A Safari Web Extension: tap Japanese text on any page for the same popup, and mine it to Anki |
| **Kaku** | 書く, to write down | A transcription server (Whisper large-v3 on an NVIDIA GPU) that writes timed Japanese transcripts of your Audiobookshelf libraries for Kiku and Yomu, and subtitles for Jellyfin episodes on request |

The apps share dictionaries, word audio sources and AnkiConnect settings on a device, so you set them
up once.

## Install on a Mac

The Mac apps are on [Homebrew](https://brew.sh), signed with Developer ID and notarized:

    brew trust zacaronii/amatsubame                # Homebrew 7 asks before using another tap
    brew install --cask zacaronii/amatsubame/yomu   # or miru, kiku, hiku

They need macOS 26 or later on Apple silicon, and `brew upgrade` updates them with each release. They
are the same apps as on TestFlight, so install each app from one place only. To build them yourself
instead, see Building below.

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

## Kaku

Kaku lives in [`Server/kaku`](Server/kaku): a Docker container for a machine with an NVIDIA GPU. See
its [README](Server/kaku/README.md) to run it and [docs/kaku.md](docs/kaku.md) for its API.

## Documentation

User guides are at [amatsubame.com](https://amatsubame.com) (source in [`site/`](site)). Developer notes are in
[`docs/`](docs): one file per app ([yomu](docs/yomu.md), [miru](docs/miru.md), [kiku](docs/kiku.md),
[hiku](docs/hiku.md), [kaku](docs/kaku.md)), the shared pieces ([shared.md](docs/shared.md)), and the
original plans ([PLAN.md](docs/PLAN.md), [AUDIO_PLAN.md](docs/AUDIO_PLAN.md),
[NAMING.md](docs/NAMING.md)). [CLAUDE.md](CLAUDE.md) holds the project's rules and commands for
contributors and coding agents.

## Contributing

Bugs and ideas are GitHub issues. Work goes issue → branch → pull request → `dev`, and `dev` goes to
`main` when it has been tried and is ready to ship. [CLAUDE.md](CLAUDE.md) has the conventions.

### Branches

- **`dev`** is where work lands. Each fix or feature is a branch from `dev` and a pull request back
  into it, merged once the builds and tests pass. Dev TestFlight builds (iPhone, iPad and Mac) come
  from `dev`, so testing always covers everything merged so far.
- **`main`** only gets what has been tried. One pull request, `dev` → `main` (labelled `chore`), is
  merged when the next release is ready; releases come from `main`. It stays the default branch, so
  `Fixes #N` closes an issue when its fix reaches `main`. Until then the issue carries `in dev`.
- **Something wrong after a merge** gets a new pull request into `dev`, not a reopened one. If the
  problem was in something not yet released, label it `follow-up`: release notes leave it out, since
  users only ever see the fixed version. A change that breaks `dev` badly can be reverted (GitHub's
  Revert button on the pull request) and redone.
- **An urgent fix for a release** is a branch from `main` and a pull request into it; `main` is then
  merged into `dev`.

### Releasing

The four apps share one version (`MARKETING_VERSION` in `project.yml`), 0.x while in beta: the middle
number goes up for features, the last one for fix-only releases. They also share one build number,
the upload time, which only goes up.

- `scripts/upload-dev.sh` uploads the current commit (normally `dev`) to the TestFlight **Dev** group
  and tags it `build-<number>`. A release doesn't rebuild: it promotes a Dev build that has been in use,
  once `dev` has been merged into `main`.
- `scripts/release.sh <build number>` checks that build's commit, tags it `v<version>`, creates the
  GitHub pre-release with generated notes, and opens the pull request that moves `dev` to the next
  fix version (0.2.0 out → 0.2.1), so every Dev build already carries the version it would ship as.
  The build is then added to the main tester group in App Store Connect.
- The same run makes the Mac apps for Homebrew: the build's Mac archives exported with Developer ID,
  notarized, stapled and attached to the GitHub release as `<App>-<version>.zip`, and the casks in
  [zacaronii/homebrew-amatsubame](https://github.com/zacaronii/homebrew-amatsubame) moved to them.
  `scripts/release.sh --mac-only <build number>` redoes just that part for a released build.
- The first feature (a PR labelled `idea` or `enhancement`) merged after a release also moves `dev`
  to the next feature version (0.2.1 → 0.3.0). If that's forgotten, the release script stops and
  says so.

When:

- About every two weeks: ship what has merged into `dev` if it passes the checklist; skip the cycle if
  nothing worthwhile merged.
- A merged bug fix shouldn't wait more than about a week: do a fix-only release if needed.
- TestFlight builds expire after 90 days, so never go more than about two months between releases.
- Bigger features use a GitHub milestone (for example "v0.4.0") and ship once its issues are closed.

The checklist (the script checks all but the third and last, and asks about those):

- All four apps build for iOS and macOS.
- The tests pass: the packages, the apps' unit tests and Kaku's.
- Every pull request since the last release was checked by hand.
- No open issue has the "blocks release" label.
- The version fits: the middle number for a release with features, the last for fixes only.
- The build has been in use in the Dev group for a day or two.

## Acknowledgements

Amatsubame stands on the work of many people. Thank you to:

**Built on and inspired by**
- [hoshidicts](https://github.com/Manhhao/hoshidicts) by Manhhao, in
  [bee-san's fork](https://github.com/bee-san/hoshidicts) that Hachidori uses: the dictionary engine
  behind every lookup. Manhhao's Hoshi Reader was an inspiration too.
- [Yomitan](https://github.com/yomidevs/yomitan): its dictionary format, deinflection rules and popup
  design shaped how lookup works here.
- [Hachidori](https://github.com/bee-san/hachidori) by bee-san: the apps follow its lead on popup
  details and recommended dictionaries, and can link to a Hachidori host to share lookups and
  dictionaries.
- [Jiten](https://jiten.moe): its underlines on known words inspired the word marks in every app.
- [Nagare](https://github.com/bpwhelan/Nagare): its mineable stream of subtitles inspired Miru's
  Lines, the running list of lines (from Miru or another Jellyfin player) you can scroll back
  through, look up and mine.
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
