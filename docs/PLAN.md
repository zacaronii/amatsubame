# Japanese Immersion App — Game Plan

The original plan, written 2026-10-30 and revised 2026-10-31 (three focused apps, see below). It's kept as design history: the per-app docs (`docs/yomu.md`, `docs/miru.md`, `docs/hiku.md`, `docs/kiku.md`) describe what was actually built.

> **Names (2026-11-03):** the apps are now **Yomu** (the Reader), **Miru** (the Player) and **Hiku**
> (the Browser/Safari extension, formerly "Japanese Lookup"), under the brand Amatsubame; the planned audio
> app is **Kiku** and its transcriber **Kaku** (docs/NAMING.md, docs/AUDIO_PLAN.md). The phase notes
> below keep the names used at the time (Reader = Yomu, Player = Miru, Browser or Japanese Lookup = Hiku;
> their targets were later renamed to match).

> **Revision (2026-10-31): three focused apps instead of one.** Each app stays focused on its purpose,
> at the cost of some duplicated work:
> 1. **Reader** (Yomu): Kavita manga and EPUBs (this app, phases 0–5).
> 2. **Player** (Miru): Jellyfin video through mpv, with subtitle lookup and mining.
> 3. **Browser** (Hiku): a Safari Web Extension with a small container app, so lookups and mining work in
>    real Safari (tabs, logins, passwords, content blockers and sync for free) instead of a WKWebView browser.
>
> **Decisions (defaults, can be revisited):**
> - **One repo, one XcodeGen project, one app target per app.** All share `Packages/*`.
> - **Shared code:** dictionary, lookup popup, mining, Anki, outbox and settings screens. The settings
>   screens and service wiring move from the first app's target into a shared `AppCommon` package.
> - **Data:** each app keeps its own data for now (its own dictionary import and settings). An App
>   Group can share it later (on devices it needs a paid Apple Developer Program team).
> - **Browser:** the extension's native side (Swift) runs hoshidicts and the Anki code; the content
>   script shows the same HTML popup in the page. [Yomikiri](https://github.com/BlueGreenMagick/yomikiri)
>   proves the approach on iOS. Prototype first: native-side memory with Jitendex loaded, and tap → popup latency.
>
> The sections below are the original single-app plan. Where they say "the app", read the app
> that owns that feature. The roadmap at the end reflects the revision.

## Overview

Build a native Swift app for iPhone and iPad (Mac as a bonus) that reads manga and EPUBs from Kavita, plays video from Jellyfin through mpv, and turns any Japanese text on screen into a Yomitan-style lookup that mines cards to Anki. Progress always syncs back to the server, and everything keeps working offline, then catches up when the connection returns.

**Goals**

- One lookup popup everywhere: manga (via OCR), EPUBs, video subtitles and a built-in browser.
- Kavita reading progress and Jellyfin watch progress written back to your server.
- Cards mined to your existing AnkiConnect container, queued locally when offline.
- Downloads for offline reading and watching.
- Works on iPhone, iPad and any new screen size; runs on Mac as a bonus.

**Non-goals (for now)**

- App Store release. The apps are built from source and installed from Xcode or TestFlight (see Licensing).
- Managing the library itself (scanning, metadata). Kavita and Jellyfin keep that job.
- Languages other than Japanese.

**How to use this doc with Claude Code:** keep it in the repo as `docs/PLAN.md`, point `CLAUDE.md` at it, and build one phase per session. Each phase has acceptance criteria Claude Code can test against.

## Platforms and tech stack

One multiplatform SwiftUI app target covering iOS, iPadOS and native macOS, with platform-specific code kept behind small protocols. Target the current OS (iOS/iPadOS/macOS 26) and use the newest APIs freely; it can be lowered to iOS 18 later if needed.

| Piece | Choice | Why / notes |
| --- | --- | --- |
| UI | SwiftUI, Observation (`@Observable`) | Adaptive layouts via size classes, so iPhone, iPad, split view and new screen shapes need no special casing |
| Project file | XcodeGen (`project.yml`) | Claude Code edits a readable YAML file instead of the fragile `.pbxproj` |
| Video | [MPVKit](https://github.com/mpvkit/MPVKit) (libmpv + FFmpeg via Swift Package Manager) | Supports iOS and macOS; default build is LGPL-3.0, the `-GPL` variant adds Samba. Use the LGPL build. Metal rendering is still a patch, so start with its default view |
| Local database | GRDB (SQLite) | Fast indexed lookups over millions of dictionary rows; also holds library cache, progress and the sync outbox |
| Manga OCR (on-device) | [nemu Core ML models](https://huggingface.co/nemu-pm/nemu-ocr-coreml) (Apache-2.0) | Text/bubble detector + manga-ocr split into encoder/decoder; iOS 17+, runs on the Neural Engine. Their benchmark: 1.1% character error vs 18.7% for Apple Vision |
| EPUB + browser rendering | WKWebView with an injected JavaScript bridge | Same tap-to-lookup bridge serves EPUBs (vertical text via CSS `writing-mode`) and web pages |
| Networking | URLSession async/await, `NWPathMonitor`, Background Tasks | Downloads, reachability, and flushing the offline queue |
| Secrets | Keychain | Kavita auth key, Jellyfin token, AnkiConnect key |

**Mac support.** Since MPVKit, Core ML, GRDB and WKWebView all run on macOS, a native Mac build mostly costs layout polish (menus, keyboard shortcuts, hover instead of tap). Keep the Mac destination building from day one so it never drifts; treat polish as the last phase.

**Licensing.** The apps are GPL-3.0 (`LICENSE`): hoshidicts and Yomitan's deinflection data are GPL-3.0 and linked into every app. MPVKit's LGPL build stays dynamically linked and replaceable. Third-party notices are in `THIRD_PARTY_NOTICES.md`. An App Store release would need the hoshidicts author's permission, since Apple's terms add restrictions the GPL doesn't allow.

## Architecture

```
MEDIA VIEWS                 SHARED CORE                   YOUR SERVER
                            ┌───────────────────────┐
                            │ Dictionary DB         │
                            │ Yomitan dicts, SQLite │
                            └───────────▲───────────┘
┌──────────────────┐        ┌───────────┴───────────┐     ┌──────────────┐
│ Manga reader     │──┐     │ Lookup + popup        │  ┌─▶│ Kavita       │
│ (Kavita + OCR)   │  │     │ one shared service    │  │  └──────────────┘
├──────────────────┤  │ text│ mines cards to outbox │  │  ┌──────────────┐
│ EPUB reader      │──┼────▶└───────────┬───────────┘  ├─▶│ Jellyfin     │
├──────────────────┤  │     ┌───────────▼───────────┐  │  └──────────────┘
│ Video player     │──┤prog.│ Outbox + sync worker  │  │  ┌──────────────┐
│ (mpv + subs)     │  ├────▶│ queues progress/cards │──┴─▶│ AnkiConnect  │
├──────────────────┤  │     │ sends when online     │     └──────────────┘
│ Browser          │──┘     └───────────────────────┘     ┌ ─ ─ ─ ─ ─ ─ ─┐
└──────────────────┘                                        Mokuro companion
                                                          │ (optional)   │
                                                          └ ─ ─ ─ ─ ─ ─ ─┘
```

Every media view hands text to one shared lookup service, and nothing writes to a server directly: progress and mined cards land in the local outbox, and a sync worker delivers them when a connection exists. Content (pages, EPUBs, video) streams from Kavita and Jellyfin, or plays from downloads.

**Code layout** (local Swift packages inside the repo, so each part builds and tests on its own):

| Package | Contents |
| --- | --- |
| `Core` | Models, GRDB database, Outbox, sync worker, Keychain, reachability |
| `Dictionary` | Yomitan import, deinflection, lookup, audio sources |
| `Lookup` | Shared popup UI, recursive lookup, mining action |
| `Anki` | Field mapping, AnkiConnect client |
| `KavitaKit` / `JellyfinKit` | API clients with fixture-based tests |
| `OCR` | Core ML pipeline, reading order, OCR cache, mokuro file parser |
| `Readers` | Manga reader, EPUB reader, browser (with the shared JS bridge) |
| `Player` | MPVKit wrapper, subtitle overlay, screenshot and audio capture |
| `App` (now the `Yomu` target) | Navigation, library screens, settings, downloads |

**Outbox.** One table of pending jobs (`ankiNote`, `kavitaProgress`, `jellyfinProgress`) with payload, media file paths, attempts and last error. Progress jobs for the same chapter or item collapse to the newest one; cards are never dropped, only retried.

## Feature specs

Every feature feeds the same pipeline: get Japanese text plus its context, look it up, show the popup, and optionally mine a card. Build that pipeline once and plug each media type into it.

### Dictionary and lookup engine (the core)

- Import Yomitan dictionary zips (`index.json`, `term_bank_*.json`, `term_meta_bank_*.json` for frequency and pitch, `kanji_bank_*.json`, `tag_bank_*.json`) into SQLite, following the [Yomitan v3 schemas](https://github.com/themoeway/yomitan/blob/master/ext/data/schemas/dictionary-term-bank-v3-schema.json). Import in the background with progress; big dictionaries like Jitendex take minutes.
- Lookup: from the tapped character, try the longest substring first (about 20 characters), run Japanese deinflection, and match term or reading. Port Yomitan's Japanese transform rules to Swift, with unit tests built from Yomitan's test cases.
- Results show dictionary order you set, frequency badges, pitch accent and audio. Support structured-content glossaries (render as HTML in a small web view or as attributed text).
- Recursive lookup inside the popup, and lookup history.
- Audio sources configurable as URL templates (like Yomitan), plus an optional local audio server.
- Prior art worth studying: [Hoshi Reader](https://apps.apple.com/app/hoshi-reader/id6758244332) does Yomitan-style lookup with deinflection on iOS already; check the license of any code before reusing it.

### Anki mining with offline queue

- Settings screen mirrors Yomitan's: pick deck and note type, map each field to a marker (`{expression}`, `{reading}`, `{furigana}`, `{glossary}`, `{sentence}`, `{picture}`, `{audio}`, `{pitch}`, `{frequency}`, `{source}`).
- Mining never talks to the network directly. It writes a card to the local outbox (fields + media files on disk) and returns instantly.
- A sync worker sends queued cards to your AnkiConnect container with `addNote`, attaching the screenshot and audio as base64 `picture`/`audio` entries ([AnkiConnect media support](https://git.foosoft.net/alex/anki-connect/commit/7ef10e92daf1ff03ff9f56c334b78f1841c5875d)). It runs when the app opens, when the network returns, and in background refresh.
- A queue screen shows pending, sent and failed cards with retry and edit.
- When online, check duplicates with `findNotes` before mining and mark already-mined words in the popup. Offline, check against the local outbox and a cached list of mined words.
- Deck, note type and field lists are cached so the settings work offline.

**Default mapping: Lapis.** Ship a built-in Lapis preset: the word, its reading and furigana, word audio, the main definition (first dictionary, usually Jitendex), the full glossary, a short definition in SelectionText (the first three senses' first glosses, no examples or notes; Lapis shows it first, the full entries a tap away), the sentence with the word highlighted, sentence audio, the picture, pitch accent, and the JPDB frequency value for the frequency-sort field. Read the exact field names from your note type with AnkiConnect's `modelFieldNames` instead of hardcoding them, so a Lapis update doesn't break mining.

### Kavita reader (manga + EPUB)

- Browse libraries, series, volumes and chapters; continue-reading shelf from Kavita's progress.
- Manga: paged and long-strip modes, right-to-left, double-page spreads on iPad, pinch zoom. Pages stream from Kavita's reader endpoints and are cached.
- EPUB: WKWebView renderer with vertical (縦書き) and horizontal modes, paginated or scrolling, font and theme settings.
- Progress: write page (manga) or page plus position (EPUB `bookScrollId`) to Kavita's reader progress endpoint, debounced, through the same outbox so offline reading syncs later. On open, compare server and local progress and resume from the newer one.
- Auth: Kavita auth key in the `x-api-key` header ([Kavita API guide](https://wiki.kavitareader.com/guides/api)). Kavita no longer serves Swagger on normal installs, so verify exact endpoint shapes against your server's version and the [API docs](https://wiki.kavitareader.com/en/guides/misc).

### Manga OCR

- On-device first: run the detector on the page, sort blocks into manga reading order, then recognize each block. Cache results per page in SQLite so each page is processed once.
- Display an invisible tappable text layer over each block (like mokuro). Tap a character to look it up; the whole block becomes the card's sentence and a crop of the panel or page becomes the picture.
- ~~If a `.mokuro` file exists on the server for that volume, use it instead of running OCR.~~ Dropped 2026-11-01: on-device OCR only.
- Manual fallback: drag a box to OCR any region, for text the detector misses.
- Run OCR ahead on the next few pages while reading, and on whole volumes when downloading.

### Jellyfin player (mpv), a separate Player app since 2026-10-31

- Browse libraries, continue watching, seasons and episodes. Auth with Jellyfin username and password, then store the access token.
- Play with MPVKit, direct-playing the original file when possible. Load Japanese subtitle tracks (embedded or external) and allow a secondary English track.
- Subtitle lookup: observe mpv's `sub-text`, `sub-start` and `sub-end` properties and draw the current line as a native, tappable overlay. Tapping pauses playback and opens the popup.
- Mining: screenshot via mpv's `screenshot-to-file` and a sentence-audio clip cut from `sub-start` to `sub-end` with the bundled FFmpeg libraries. Subtitle list view for jumping between lines and mining past ones.
- Progress: report start, progress (every ~10 seconds) and stop to Jellyfin's `/Sessions/Playing`, `/Sessions/Playing/Progress` and `/Sessions/Playing/Stopped` endpoints, in ticks (10,000 ticks = 1 ms). Offline viewing queues the final position in the outbox.

### Browser (now a Safari Web Extension; original built-in browser notes kept for reference)

- **Revised:** a Safari Web Extension plus a container app (settings, dictionaries, AnkiConnect, cards, queue).
  - **Content script:** catches taps on text, reads the sentence, and shows the popup in the page.
  - **Native side:** `sendNativeMessage` via the background page runs the lookup and the mining.
  - **Sharing with the container app** needs an App Group (a paid developer team on devices).
- **Original:** WKWebView with tabs, bookmarks (NHK News Web Easy, etc.) and a reader mode.
- The injected script finds the tapped character with `caretRangeFromPoint` and sends the surrounding text to Swift; the native popup appears over the page. The sentence comes from the paragraph, the source is the page URL.
- Optional: let any page open in the browser from the iOS share sheet.

### Offline downloads

- Download Kavita volumes (pages or EPUB), their OCR results and covers; download Jellyfin episodes (original file) with their subtitle files.
- Downloads tab with storage use and delete. Readers and player prefer local files automatically.
- Everything written while offline (progress, cards) goes through the outbox and syncs later.

## Server-side pieces

Nothing new is required on the server: the app uses Kavita, Jellyfin, AnkiConnect and your remote access as they are. Mokuro was considered as an optional upgrade and dropped on 2026-11-01 (on-device OCR uses the same manga-ocr recognizer that mokuro does).

| Piece | Needed | What the app needs from it |
| --- | --- | --- |
| Kavita | Yes | An auth key for the app's user |
| Jellyfin | Yes | A user account; app logs in and stores a token |
| AnkiConnect container | Yes | Reachable remotely, with an API key set, and syncing to AnkiWeb so cards reach your phone's AnkiMobile |
| Remote access (Tailscale, VPN or reverse proxy) | Away from home | All three services reachable away from home over HTTPS or the tailnet |
| Mokuro pre-processing | Dropped 2026-11-01 | `.mokuro` files for library volumes |
| Small companion service | Dropped 2026-11-01 | Serves `.mokuro` files matched to Kavita chapters |

**Mokuro options.** Mokuro writes a `.mokuro` file per volume holding the detected text boxes and OCR text ([mokuro](https://github.com/kenrick95/mokuro)).

- [mokuro-bridge](https://pypi.org/project/mokuro-bridge/1.0.1/): a FastAPI service that outputs `.cbz` + `.mokuro` + cover per series. Its docs say it is designed to stay loopback-only and unauthenticated, and it is built around capturing pages from store downloaders, so it may need a wrapper to process an existing Kavita folder.
- Plain `mokuro --parent_dir` run nightly over the Kavita manga folder (cron or a scheduled container). Simplest if mokuro-bridge doesn't fit.

Either way the app needs a way to fetch those files, since Kavita won't serve them. The companion service (a tiny container, also behind Tailscale with a token) looks up a Kavita chapter's file path through the Kavita API and returns the matching `.mokuro` JSON, or 404 so the app falls back to on-device OCR.

**Security.** Keep every service off the open internet unless it's behind a reverse proxy with HTTPS. Store all keys in the iOS Keychain.

## Roadmap

The minimum useful app (read manga from Kavita, tap to look up, mine to Anki) lands at the end of phase 4; that's the first TestFlight build. Each phase ends with something usable on the phone.

0. **Foundation.** XcodeGen project with iOS and macOS destinations, GRDB database, Keychain, settings screens for Kavita, Jellyfin and AnkiConnect, and the outbox skeleton.
   - Done when: builds for iPhone simulator, iPad simulator and Mac; each server has a working "Test connection" button that also shows the server's version; unit tests run with `xcodebuild test`.
1. **Kavita manga reader.** Library browsing, paged and long-strip reading, right-to-left, iPad spreads, page caching, progress write-back through the outbox.
   - Done when: reading 5 pages on the phone shows the same page in Kavita's web reader; reading offline syncs on reconnect.
2. **Dictionary engine.** Yomitan zip import, deinflection port, lookup, popup UI with frequency, pitch and audio, plus a search screen for testing.
   - Done when: Jitendex, JPDB frequency and a pitch dictionary import; 食べさせられなかった finds 食べる; deinflection tests pass.
3. **On-device manga OCR.** Core ML pipeline, reading order, tappable text overlay, per-page caching, manual box OCR.
   - Done when: tapping a word in a speech bubble opens the popup in under about 1 second on the iPhone.
4. **Anki mining.** Lapis preset, field mapping, outbox, AnkiConnect sync with media and API key, duplicate marking, queue screen.
   - Done when: a card mined in airplane mode (sentence + page crop) appears in Anki after reconnecting. **First TestFlight build.**
5. **EPUB reader.** WKWebView renderer, vertical text, JS lookup bridge, Kavita EPUB progress. *(Done.)*

Revised from here on (2026-10-31), for three focused apps:

6. **Restructure for several apps.** *(Done 2026-10-31: `Packages/AppCommon`, Japanese Reader + empty Japanese Player.)* Move the shared settings screens (servers, dictionaries, audio sources, cards, queue, storage) and service wiring from the App target into a shared `AppCommon` package. Rename the current app target to the Reader and add an empty Player target. Both build for iOS and Mac.
   - Done when: the Reader works exactly as before (all tests pass), and the Player target launches with the shared Settings.
7. **Player app (Jellyfin + mpv).** *(Built 2026-10-31; MPVKit LGPL adds ~34 MB on iPhone.)* Browsing, playback, subtitle overlay lookup, screenshot and sentence-audio mining, progress reporting (the original phase 6 content).
   - **Lines tab** (replaces dictionary Search, which stays in the Reader):
     - Everything watched or started in Jellyfin, on any device, from visible libraries. An episode opens as a feed of tappable lines: look up, mine (line audio + screenshot), "Play from here".
     - Full-text search across saved transcripts (FTS5 trigram; LIKE for 1–2 character words).
     - **Live feed:** "Watching Now" follows playback on another device (TV, web) line by line; tapping a word pauses that device when it accepts remote control.
     - Subtitles are saved per episode when played or opened, so Lines works offline.
   - **Typed lookup:** a magnifier button in the player opens dictionary search over the paused video, for words heard but not on screen.
   - Done when: watching 2 minutes updates Jellyfin's resume point; a mined card has the line's audio and a screenshot.
8. **Downloads, per app.** *(Built 2026-10-31.)* The Reader saves volumes (EPUB or pages, OCR'd ahead) and the Player saves original episode files with their subtitles; a Downloads tab in each app, Wi-Fi only unless allowed, kept until deleted.
   - Make it clear what's on the device and what isn't, allow offloading volumes, series and episodes, and show storage use.
   - Nothing downloads unless the user opens it or asks for it; opened books stay in the size-limited cache.
9. **Safari extension + container app.** *(Built 2026-11-01.)* Japanese Lookup: tap Japanese text in Safari for the same popup as the apps, on iPhone and iPad.
   - **Shared setup:** dictionaries, audio sources and AnkiConnect are shared through the App Group between the Reader, Player and Japanese Lookup. Each app can opt out ("Share Setup with My Other Apps"). On devices the App Group needs a paid developer team; without it, the extension uses built-in dictionaries.
   - **Mining and audio (2026-11-01):** the popup plays word audio, follows glossary links (with Back) and adds cards to Anki (sentence; source = page title and address; 5 s Undo, then sent through the outbox). Until the App Group, AnkiConnect and the deck are set in the extension's menu in Safari.
10. **Polish, per app.** Mac menus and keyboard shortcuts, new screen sizes, stats if wanted.
    - Pass 1 done 2026-10-31: Player gestures (tap, two-finger pause, double-tap skip, scrub, edge brightness/volume, subtitle swipe), faster rotation reconfigure, steady live feed, Mac reading in the main window, popups kept inside the window, Reader/Playback menus and tab shortcuts.
    - Pass 2 done 2026-10-31 (from testing on an iPhone):
      - Infuse-style scrubbing with a picture preview (frames grabbed from the video, or Jellyfin trickplay when the server makes it);
      - only play/pause in the middle of the screen;
      - the video layer keeps the video's shape, so rotation no longer squashes it;
      - the live feed no longer runs ahead and snaps back;
      - Skip Intro / Skip Credits from Jellyfin media segments (optional auto-skip);
      - the Downloads empty state no longer covers the list.
    - After pass 2:
      - the scrub preview no longer resizes the video;
      - the two-finger tap pauses quietly;
      - the player's search button finds Japanese subtitles on Jimaku, with a timing fix;
      - (2026-11-01) picking a file only tries it; "Save to Jellyfin…" (confirmed) uploads it as `<episode>.ja.<ext>`, the server's naming;
      - Auto-Sync retimes it on the device the way alass does: to the video's own subtitle track, else to the speech in its audio (libfvad).
    - Last pass (2026-11-01), the Reader's downloads, so the Downloads tab is only needed to check storage:
      - a manga volume is downloaded once its pages are in; reading its text follows as its own labelled step;
      - automatic downloads per library: once a series is started, keep the volume being read and N after it, optionally removing finished volumes;
      - offline, the Library shows only series with downloaded volumes.
      Phase 10 ends with it.
    - **Mokuro:** dropped (2026-11-01); on-device OCR stays the only OCR.

**After phase 10:** no new phases are planned up front. Bugs and ideas are tracked as GitHub issues (labels: Reader, Player, Extension, Kiku, Kaku, Shared, bug, idea, polish, perf, question), and the next work is planned from them. The audio app and transcriber followed in docs/AUDIO_PLAN.md.

## Setup the plan assumed

| Item | Assumption | What it means for the build |
| --- | --- | --- |
| Devices | Current OS everywhere | Target iOS, iPadOS and macOS 26 only |
| Anki note type | Lapis | Ship Lapis as the default field mapping (phase 4) |
| Dictionaries | Jitendex, JPDB frequency, a pitch accent dictionary | Phase 2 must import and display all three; use them as test fixtures |
| Kavita / Jellyfin versions | Vary per server | Phase 0's "Test connection" reads and shows each server's version (Jellyfin `/System/Info/Public`, Kavita's server-info endpoint); API clients are checked against those versions |
| AnkiConnect | Syncs to AnkiWeb, reachable remotely, with an API key | The app sends the key with every request |

## Risks

| Risk | Impact | Fallback |
| --- | --- | --- |
| MPVKit's Metal rendering is still a patch | Video glitches or battery drain | Use MPVKit's default (non-Metal) rendering until Metal support stabilizes |
| Sentence-audio clipping on device | Hardest mining feature | Cut audio on the server with FFmpeg from the Jellyfin file instead |
| Kavita API shapes change between versions | Progress sync breaks | API client isolated behind a protocol with fixture tests; check after Kavita upgrades |
| OCR model memory on older devices | Slow or crashing OCR | Process one block at a time; fall back to Apple Vision |
| Deinflection port accuracy | Missed lookups | Test suite from Yomitan's cases; compare results against Yomitan on desktop |

## Getting builds onto devices

- With a free Apple ID: run on iPhone/iPad from Xcode (installs expire after 7 days, and the App Group for the shared setup isn't available).
- With a paid developer team: archive and upload with `xcodebuild archive` and `xcodebuild -exportArchive`, then install through TestFlight on every device.

## Sources

- [MPVKit](https://github.com/mpvkit/MPVKit)
- [nemu on-device manga OCR (Core ML)](https://huggingface.co/nemu-pm/nemu-ocr-coreml)
- [mokuro](https://github.com/kenrick95/mokuro) · [mokuro-bridge](https://pypi.org/project/mokuro-bridge/1.0.1/)
- [Kavita API guide](https://wiki.kavitareader.com/guides/api)
- [Jellyfin playback reporting endpoints (example implementation)](https://github.com/timusus/Shuttle2/pull/191)
- [AnkiConnect media in addNote](https://git.foosoft.net/alex/anki-connect/commit/7ef10e92daf1ff03ff9f56c334b78f1841c5875d)
- [Yomitan term bank schema](https://github.com/themoeway/yomitan/blob/master/ext/data/schemas/dictionary-term-bank-v3-schema.json)
- [Hoshi Reader (App Store)](https://apps.apple.com/app/hoshi-reader/id6758244332)
