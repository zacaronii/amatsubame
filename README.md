<p align="center">
  <img src="docs/media/banner.png" alt="Amatsubame: Japanese immersion apps for your own media servers" width="720">
</p>

<p align="center">
  <a href="https://github.com/zacaronii/amatsubame/releases"><img alt="Latest release" src="https://img.shields.io/github/v/release/zacaronii/amatsubame?include_prereleases&label=release"></a>
  <img alt="Platforms: iOS, iPadOS, macOS 26" src="https://img.shields.io/badge/platforms-iOS%20%7C%20iPadOS%20%7C%20macOS%2026-blue">
  <a href="LICENSE"><img alt="License: GPL-3.0" src="https://img.shields.io/badge/license-GPL--3.0-green"></a>
  <a href="https://amatsubame.com"><img alt="Guides: amatsubame.com" src="https://img.shields.io/badge/guides-amatsubame.com-8a7fd6"></a>
</p>

<p align="center">
  Japanese immersion apps for your own Kavita, Jellyfin and Audiobookshelf.<br>
  One dictionary popup everywhere, and cards straight to Anki.
</p>

| | App | | |
| :-: | --- | --- | :-: |
| <img src="docs/media/yomu-icon.png" width="64" alt=""> | **Yomu**<br>読む, to read | Manga and light novels from Kavita, with on-device text recognition and read-along | ![TestFlight soon](https://img.shields.io/badge/TestFlight-soon-lightgrey) |
| <img src="docs/media/miru-icon.png" width="64" alt=""> | **Miru**<br>見る, to watch | Jellyfin video with tappable Japanese subtitles | ![TestFlight soon](https://img.shields.io/badge/TestFlight-soon-lightgrey) |
| <img src="docs/media/kiku-icon.png" width="64" alt=""> | **Kiku**<br>聞く, to listen | Podcasts and audiobooks from Audiobookshelf with tappable transcripts | ![TestFlight soon](https://img.shields.io/badge/TestFlight-soon-lightgrey) |
| <img src="docs/media/hiku-icon.png" width="64" alt=""> | **Hiku**<br>引く, to look up | Tap Japanese on any page in Safari | ![TestFlight soon](https://img.shields.io/badge/TestFlight-soon-lightgrey) |

**Kaku** (書く, to write down) is the optional transcription server behind Kiku's transcripts:
[`Server/kaku`](Server/kaku). No servers of your own? Setup offers demo servers to try the apps with.

| App | Home | In use |
| --- | --- | --- |
| **Yomu** | <img src="docs/media/yomu-1-home.png" width="200" alt="Yomu's Library with the demo server's manga and books"> | <img src="docs/media/yomu-2-lookup.png" width="200" alt="Yomu: 出来上がり looked up in a speech bubble of Pepper&amp;Carrot"> |
| **Miru** | <img src="docs/media/miru-1-home.png" width="200" alt="Miru's Watch home with the demo server's films"> | <img src="docs/media/miru-player.gif" width="200" alt="Miru: Sintel playing with its Japanese subtitles, and 汚れる looked up in the line"> |
| **Kiku** | <img src="docs/media/kiku-1-home.png" width="200" alt="Kiku's Listen home with the demo server's audiobooks"> | <img src="docs/media/kiku-player.gif" width="200" alt="Kiku: 坊っちゃん playing with its transcript following, and 小学校 looked up"> |
| **Hiku** | <img src="docs/media/hiku-1-home.png" width="200" alt="Hiku's screen in the app"> | <img src="docs/media/hiku-2-lookup.png" width="200" alt="Hiku: 無鉄砲 looked up on Aozora Bunko in Safari"> |

## Get started

Guides for every app are at [amatsubame.com](https://amatsubame.com). The Mac apps are on
[Homebrew](https://brew.sh) (the iPhone and iPad apps are on TestFlight):

    brew install --cask zacaronii/amatsubame/yomu   # or miru, kiku, hiku

They're signed with Developer ID, notarized and need Apple silicon. Testers can follow every Dev build
with the `@dev` casks instead (`zacaronii/amatsubame/yomu@dev` and so on); a release cask and its
`@dev` cask are the same app, so install one of the two.

## Build from source

    brew install xcodegen
    xcodegen && open Amatsubame.xcodeproj

Requirements, signing for your own devices and more: [docs/BUILDING.md](docs/BUILDING.md).
Developer notes are in [`docs/`](docs).

## Contributing

Bugs and ideas are [GitHub issues](https://github.com/zacaronii/amatsubame/issues/new/choose).
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) has the workflow, and [CLAUDE.md](CLAUDE.md) the
project's rules for contributors and coding agents.

### Branches

Work lands in `dev` through pull requests; `main` gets only what has been tried, through one
`dev` → `main` pull request. Details: [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md#branches).

### Releasing

Releases promote a Dev TestFlight build that has been in use: [docs/RELEASING.md](docs/RELEASING.md).

## License

The apps are licensed under the [GNU General Public License, version 3 only (GPL-3.0-only)](LICENSE): they link the GPL-3.0
dictionary engine [hoshidicts](https://github.com/Manhhao/hoshidicts). Kaku is a separate program under
the [MIT License](Server/kaku/LICENSE). Third-party components and their licenses are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Amatsubame stands on the work of many people: see [docs/ACKNOWLEDGEMENTS.md](docs/ACKNOWLEDGEMENTS.md).
The screenshots and GIFs show licence-clean content: [credits](docs/media/CREDITS.md). The demo servers' books, manga,
audiobooks and films are credited in [CREDITS.md](CREDITS.md).
