# Amatsubame: Japanese immersion apps

Instructions for AI coding agents working on this repo. Focused apps in one repo, under the brand Amatsubame (names and icons: docs/NAMING.md). The original plan is docs/PLAN.md; the audio app and transcriber are planned in docs/AUDIO_PLAN.md. Read the doc for the area you're working on before starting, and plan larger changes before writing code.

## Project map
The Xcode project is generated as `Amatsubame.xcodeproj` from `project.yml`.

| App | What it does | Target / scheme | Built app | Bundle ID | Notes |
| --- | --- | --- | --- | --- | --- |
| **Yomu** (読む) | Kavita manga + EPUB, OCR, read-along | `Yomu` (tests `YomuTests`, `YomuUITests`) | `Yomu.app` | `com.amatsubame.yomu` | [docs/yomu.md](docs/yomu.md) |
| **Miru** (見る) | Jellyfin + mpv, tappable subtitles | `Miru` (`MiruTests`, `MiruUITests`) | `Miru.app` | `com.amatsubame.miru` | [docs/miru.md](docs/miru.md) |
| **Hiku** (引く) | Safari Web Extension + its container app | `Hiku` (+ `HikuExtension`; `HikuUITests`) | `Hiku.app` | `com.amatsubame.hiku` (extension `.hiku.extension`) | [docs/hiku.md](docs/hiku.md) |
| **Kiku** (聞く) | Audiobookshelf podcasts and audiobooks, transcripts from Kaku | `Kiku` (`KikuTests`, `KikuUITests`) | `Kiku.app` | `com.amatsubame.kiku` | [docs/kiku.md](docs/kiku.md) |
| **Kaku** (書く) | Transcriber container on a GPU machine: Audiobookshelf podcasts and books → timed Japanese transcripts; Jellyfin episodes on request (Miru subtitles) | `Server/kaku` | | | [docs/kaku.md](docs/kaku.md) |

The Swift modules are named after the targets (`Yomu`, `Miru`, `Kiku`, `Hiku`, `HikuExtension`). The shared setup uses the App Group `group.com.amatsubame` and the shared Keychain service `com.amatsubame.shared`. Yomu's link scheme is `amatsubame-yomu`. `SharedUITests/` holds UI test support the apps' UI test targets share.

Shared code is in `Packages/*`. Keep app-specific code out of shared packages, and keep shared UI (settings, queue) in a shared package rather than an app target.
- `Core`: database (GRDB), outbox, accounts, Keychain, the shared setup (`SharedSetup`, `SetupSharing`).
- `AppCommon`: `CommonEnvironment` (database, outbox and worker, dictionaries, lookup, mining, Anki, accounts) and the shared screens (dictionaries, audio sources, AnkiConnect, cards, queue, Search, About, `ServerRow`, `ServerSettingsModel`), the transcript pieces Miru and Kiku share (`TappableLine` with word marks, `LineLookup`, `CardSource.miscInfo`), and the audio pieces Kiku and Yomu's read-along share (`AudioPlayer`, `ClipPlayer`, `AudioClips`, the Audiobookshelf and Kaku settings, `AudioServers`). It uses the default-MainActor setting like the app targets.
- `Dictionary` (hoshidicts import and lookup, text scanning), `Lookup` (the one `LookupService` and popup, word audio, `TextTapBridge.js`), `Anki` (AnkiConnect and mining).
- `KavitaKit`, `JellyfinKit`, `JimakuKit`, `AudiobookshelfKit` (with the Kaku client Kiku, Yomu and Miru use), `KechimochiKit`: API clients with fixture tests.
- `Readers` (manga and EPUB readers), `OCR` (manga OCR), `Player` (module `PlayerKit`: mpv, `MediaClipper`, subtitles, sync), `Browser` (module `BrowserKit`: the extension's native side).
- Each app wraps `common` in its own environment (`AppEnvironment` in Yomu, `PlayerEnvironment` in Miru, `KikuEnvironment`), passes its outbox handlers through `appHandlers`, injects both into SwiftUI, and writes its own Settings screen from the shared rows.
- Data: each app has its own container; the shared setup (App Group) holds dictionaries, audio sources and AnkiConnect. See [docs/shared.md](docs/shared.md), with downloads, mining tests and AnkiConnect notes.

Contributor-specific details (your devices, simulators, local folders, server specifics) can go in an optional gitignored `CLAUDE.local.md` next to this file, which loads alongside it.

## Issues
- Bugs and ideas are tracked as GitHub issues (`gh issue list`). Work from them only when asked. Plan the fix first, and put `Fixes #N` in the commit that fixes one. Close an issue (with a short comment) once the fix is confirmed on a device.
- **Titles:** `<Prefix>: <App> – <what>`, e.g. `Bug: Yomu – EPUB page jumps back after a lookup`. Older titles use Reader/Player/Extension.

  | Prefix | Means | Label |
  | --- | --- | --- |
  | `FR:` | feature request | `idea` |
  | `Bug:` | broken or wrong | `bug` |
  | `Polish:` | works but feels off | `polish` |
  | `Perf:` | slow or heavy | `perf` |
  | `Q:` | question, look into it | `question` |

- **Labels:** issues filed from a phone often have none. When going through issues, add the label from the prefix, plus the app's label from the name in the title: `Reader` (Yomu), `Player` (Miru), `Extension` (Hiku), `Kiku`, `Kaku`, or `Shared` for the shared screens and packages that every app uses (title `<Prefix>: All apps – …`). If a title has no prefix, pick the closest one and ask if unsure.

## Stack
- Swift 6, SwiftUI, Observation. Multiplatform targets: iOS, iPadOS, macOS 26.
- XcodeGen: edit project.yml, never the .xcodeproj. Run `xcodegen` after changing it.
- Signing: `Config/Signing.xcconfig` (committed: empty `DEVELOPMENT_TEAM`, `BUNDLE_ID_PREFIX = com.amatsubame`) includes an optional gitignored `Config/Signing.local.xcconfig` that sets your team and, for anyone else's devices, their own prefix. Every target's bundle ID is `$(BUNDLE_ID_PREFIX).<app>`; Hiku finds its extension as its own bundle ID + `.extension`. `AMATSUBAME_APP_GROUP = YES` there turns on the App Group outside the simulator (paid team; docs/shared.md). Simulator builds need no team.
- GRDB for all persistence, with one approved exception: dictionary *content* is stored in hoshidicts' own format (Application Support/Dictionaries/<id>). Dictionary metadata, order, settings, audio sources and lookup history stay in GRDB. MPVKit (LGPL build) for video. Core ML for OCR.
- Speech detection for subtitle sync: libfvad (BSD-3-Clause, WebRTC's VAD), vendored in `Vendor/libfvad` (see its VENDORED.md).
- Dictionary engine: hoshidicts (GPL-3.0), vendored in `Vendor/hoshidicts` and called only through its C API (`CHoshiDicts`, no C++ interop in Swift). See `Vendor/hoshidicts/VENDORED.md` before updating it.
- Manga OCR: nemu-ocr-coreml (Apache-2.0) Core ML models, pinned by Hugging Face commit and SHA-256 in `OCRModelStore` and `scripts/fetch-ocr-models.sh` (keep both in sync). The app downloads them in Settings → Manga OCR; nothing is bundled or committed.
- Licenses: the apps are GPL-3.0 (`LICENSE`), Kaku is MIT (`Server/kaku/LICENSE`); third-party notices in `THIRD_PARTY_NOTICES.md` (update it when adding a dependency).
- Icons: the swift's SVGs in `Design/icons/<App>/` are the source (`python3 Design/make_icons.py` renders their PNGs). Each app has a layered `Resources/AppIcon.icon` (built by `python3 Design/make_layered_icon.py Design/icons/<App> <target>/Resources/AppIcon.icon`, with dark images for Dark and a light `-foreground-mono` swift for Tinted and Clear) and an `AppIcon.appiconset` fallback: the flattened `-icon-1024.png`, and Mac sizes rendered from the `.icon` with Icon Composer's `ictool` (`/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool`; `/usr/bin/ictool` is actool). Hiku's extension icons (`HikuExtension/Resources/icon-*.png`) are its iOS Default rendition. Setup's Welcome shows each app's `WelcomeIcon` image: `icon-1024.png` scaled to 288 px (`sips -Z 288`); refresh it when the icon changes.

## Rules
- All network writes (progress, Anki cards) go through the Outbox. Never call the server directly from UI.
  - One exception: the Lines live feed's Pause/Resume of another Jellyfin device is a live control command, sent directly from its model (a pause delivered late would be wrong).
- One shared LookupService and LookupPopup (in `Packages/Lookup`) used by every app: Yomu, Miru, Kiku and Hiku's rendering.
- Secrets only in Keychain. No hardcoded server URLs or keys. Live-test values come from a gitignored `.env`, handed to tests through environment variables; never commit them, and scrub recorded fixtures.
- Keep every target building, macOS included, after every change.
- Write unit tests for parsing, deinflection, the outbox and API clients (with recorded JSON fixtures).
- Verify Kavita, Jellyfin and Audiobookshelf endpoint shapes against the server versions you test with; don't assume.
- Live checks against real servers: record whatever progress a test changes and restore it afterwards, and send test cards only to a scratch deck.

## Defaults the apps are built around
- Anki note type: Lapis is the built-in preset (field names are read via AnkiConnect `modelFieldNames`, never hardcoded).
- Dictionaries: Yomitan-format zips; the apps recommend Jitendex, JMnedict, KANJIDIC, Jiten frequency and Kanjium.
- AnkiConnect reachable from the devices (with an API key), ideally syncing to AnkiWeb.

## Commands
- Generate project: `xcodegen` (writes `Amatsubame.xcodeproj`).
- Build output goes in `build.noindex/` (Spotlight skips it, so it doesn't list stray copies of the apps). Pass `-derivedDataPath build.noindex/<name>`; Mac Release builds need `ARCHS=arm64` (the OCR code's Float16 doesn't exist on Intel).
- Test: `xcodebuild test -scheme Yomu -destination 'platform=iOS Simulator,name=<any current iPhone>'`, `-scheme Miru` (its UI test runs in memory via `UITEST_PLAYER=1`), `-scheme Kiku` (`UITEST_KIKU=1`) and `-scheme Hiku`.
- Package tests: `swift test` inside a package folder (e.g. `Packages/Dictionary`).
- Docs site (amatsubame.com): Astro Starlight in `site/` (`npm install`, then `npm run dev` or `npm run build`). Pages are in `site/src/content/docs/`; a push to main that touches `site/` publishes it through `.github/workflows/site.yml` (GitHub Pages). Update the user guides when a feature they describe changes.
- Mac build: `xcodebuild build -scheme Yomu -destination 'platform=macOS'` (and `-scheme Miru`, `-scheme Kiku`, `-scheme Hiku`).
- Area-specific test setups (live Kavita, real dictionaries, OCR models, Jimaku, sync, the extension) are in each app's doc above.
- TestFlight: `scripts/upload-testflight.sh [--no-upload] [App …]` archives each app for iOS and macOS with a time-based build number and uploads it (needs the paid team, `AMATSUBAME_APP_GROUP = YES` and an App Store Connect API key in the keychain; see the script's header). Each app has a `PrivacyInfo.xcprivacy`; update it when code starts using another required-reason API.
- Kaku: `python3 -m pytest -q tests` in `Server/kaku` (no GPU needed). To run it: `docker compose up -d --build` in `Server/kaku` with a filled-in `.env` from `env.example` (details in docs/kaku.md).
