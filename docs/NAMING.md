# Naming

The app names date from 2026-11-03; the brand and mascot became Amatsubame on 2026-11-10.

## Brand: Amatsubame (アマツバメ, 雨燕)

The Japanese name of the Pacific swift (*Apus pacificus*), literally "rain swallow". Swifts almost never land: they eat, drink and even sleep in flight, and can stay airborne for months. That's the idea of immersion: never touching down out of Japanese. It replaces Kotodori (the lyrebird), whose name was already used by a Japanese marketing blog and a small GitHub SRS app. Nothing called Amatsubame turned up in the App Store or on GitHub when it was chosen.

Amatsubame is the umbrella brand, used the way Apple uses "Apple" or "iWork": the repo, the developer name, App Store subtitles and the shared mascot on every icon. It is NOT part of each app's everyday name, and the apps' own wording doesn't mention it (Settings says "Share Setup with My Other Apps", not the suite name).

- Written as **Amatsubame** (Hepburn, matching Yomu, Miru, Kiku and Hiku; never "Amatubame") and **アマツバメ** (katakana, the usual way to write bird names). 雨燕 is fine next to the kana.
- Don't shorten it to "Tsubame" (the swallow, and the name is used everywhere).
- The mascot is our own cute round bird. It doesn't copy or resemble Apple's Swift logo, and the brand name is Japanese, not "Swift".

## Apps: one short verb each

Short, Apple-style names: two-syllable everyday verbs that say what you do in the app. Standing alone (no brand prefix), they read naturally in Japanese.

| App | Name | Japanese | Meaning | Accent |
| --- | --- | --- | --- | --- |
| Reader (Kavita manga + EPUB, read-along) | **Yomu** | 読む | to read | green `#3FC98F` |
| Player (Jellyfin video) | **Miru** | 見る | to watch | purple `#AA5CC3` |
| Audio (Audiobookshelf podcasts + audiobooks) | **Kiku** | 聞く | to listen | orange `#F79A3E` |
| Lookup (Safari extension + its app) | **Hiku** | 引く | to look up (辞書を引く) | pink `#EE4F6B` |
| Transcriber (server container) | **Kaku** | 書く | to write (down) | — |

- **Home-screen label** (`CFBundleDisplayName`): the name alone, e.g. `Yomu`.
- **App Store / TestFlight title**: the name, with Amatsubame as the developer name. If a name is taken when publishing, use `Yomu — Amatsubame` or a descriptive subtitle. Existing look-alikes to keep in mind: a "Yomu – Japanese Reader" iOS app, the open-source "Miru" anime app, and the "Kiku" Anki note type.

## Mascot and icons

A round, cute Pacific swift as a **flat die-cut sticker** (since 2026-11-27): flat fills in one blue-slate family, no gradients on the bird or its props, and one white border round each icon's whole foreground, bird and prop together, so it reads on the app's gradient, on Dark's grey and in Tinted alike. True to the bird: a big round head with a darker cap, a long dark wing laid along its side, a white rump band, a pale throat round a small black bill (with a pale edge so it shows on any background), a deep forked tail, dark eyes with a sparkle and pink blush. Two cartoon liberties for character: **a three-feather tuft** (real Pacific swifts have no crest) and **tiny feet** (swifts are *Apus*, "footless", and barely use theirs). It replaced a gradient swift whose wing crossed its face, whose tail floated behind a separate rump strip and whose belly scallops read as a second mouth.

| App | Icon (the bird's personality) | Background gradient (150°) | Prop ink (Default and Dark) | Prop ink (mono) |
| --- | --- | --- | --- | --- |
| Yomu | Reading in round glasses, over an open book | `#D4F27A` → `#3FC98F` → `#0A8FA0` | `#0B4F45` | `#5FE0A8` |
| Miru | Star-eyed and chirping, watching in front of a TV screen | `#D99BEF` → `#AA5CC3` → `#0098D6` | `#4A1F63` | `#C79AE8` |
| Kiku | Eyes closed, listening in headphones | `#FFE27A` → `#F79A3E` → `#E2513A` | `#6B2410` | `#FFAE5C` |
| Hiku | Looking through a magnifying glass, its eye big in the lens | `#FF9CC0` → `#EE4F6B` → `#9E1F5E` | `#5E0F32` | `#FF7597` |

**The brand swift** (`Design/mascot/`: the README banner, the site's logo and social image) is the same sticker bird dozing mid-flight: swifts eat, drink and even sleep on the wing, as the name's story says. Wings out in a glide, eyes closed, a nose bubble (鼻ちょうちん, manga's sign for sleep) at its bill, a nightcap slipping off its tuft, and a thought cloud: it dreams 「もう一話だけ…」 ("just one more episode…"). The phrase is an outline from M PLUS Rounded 1c ExtraBold (SIL Open Font License), so it looks the same everywhere. Files: `swift.svg` (+ `swift-1024.png`) with the cloud, for the banner, the site's hero and `site/public/social.png` (`site/scripts/social-image.mjs`; the README banner is a copy); `swift-small.svg` (+ `-1024.png`) without it, for the site's header logo and favicon, where the phrase couldn't be read. One file serves light and dark: the white border carries it on both.

Files are in `Design/icons/<App>/`, all on a 100 × 100 viewBox. `Design/make_swift_icons.py` writes the foregrounds and the flattened icon (the bird and props are drawn there, not by hand); the backgrounds are kept as they are:

- `<App>-background.svg`: the gradient (unchanged from the lyrebird icons).
- `<App>-background-dark.svg`: Dark mode's background: a dark grey gradient (`#3A3A40` → `#101012`) with a soft glow of the app's middle color rising from the bottom.
- `<App>-foreground.svg` (+ `-1024.png`): the bird and prop with their white border, on transparency, for Default.
- `<App>-foreground-dark.svg` (+ `-1024.png`): for Dark. The same as Default: the white border carries the bird on the dark background (the gradient swift needed lighter greys and a rim here).
- `<App>-foreground-mono.svg` (+ `-1024.png`): a light-bodied swift with lighter prop ink for Tinted and Clear, where iOS keeps only luminance.
- `<App>-icon.svg` / `<App>-icon-1024.png`: the flattened Default icon for the asset catalog.
- `previews/<App>-<mode>.png`: Icon Composer's own rendering (`ictool`, iOS, 512 px) of Default, Dark, Clear light and dark, and Tinted light and dark.

## How it was applied

Icons:
- [x] The swift SVGs replaced the earlier lyrebird icons in `Design/icons/`, and `Design/make_icons.py` renders every PNG from them (with `rsvg-convert`, or Quick Look when it isn't installed).
- [x] `Design/make_layered_icon.py`: the foreground layer uses `-foreground-dark.svg` in the dark appearance and `-foreground-mono.svg` in tinted and clear, and the background layer uses `-background-dark.svg` in dark instead of being hidden. The glass foreground stays opaque so the white throat, rump band and props stay crisp. Only the image specializations name each layer's image: a plain `image-name` overrides them.
- [x] Each target's `AppIcon.icon` and `AppIcon.appiconset` were rebuilt (Yomu, Miru, Kiku, Hiku and `HikuExtension`).
- [x] Every appearance was exported for iOS and macOS with Icon Composer's `ictool` and compared with `previews/` (the exports are kept with the private design notes, not in the repo).

The name (Kotodori → Amatsubame):
- [x] Docs, code comments and strings (`Design/make_icons.py`, the `AppLog` subsystem fallback). App wording names the reader app, not the suite: "Read-along happens in Yomu, the reader app."
- [x] The read-along URL scheme is `amatsubame-yomu://…` (Kiku opens it; Yomu registers it). The old `kotodori-yomu` scheme was dropped at the public release.
- [x] At the public release, the internal names followed: bundle identifiers `com.amatsubame.*`, App Group `group.com.amatsubame`, the shared Keychain service `com.amatsubame.shared`, targets, schemes, folders and modules `Yomu`, `Miru`, `Kiku`, `Hiku` and `HikuExtension`, and the project `Amatsubame.xcodeproj`.

Compared with `previews/`, ictool's renderings:
- Default and Dark match.
- Clear light comes out greyer and lower in contrast than the preview. ictool renders it over its own mid-grey backdrop, so part of that is the backdrop; check it on a device.
- Tinted uses ictool's default purple tint, not the preview's blue. With `-foreground-dark` the swift was very faint in Tinted dark (Yomu, Kiku, Hiku); since `-foreground-mono` took over Tinted and Clear it reads clearly in all four, and Clear light shows a light bird on the grey glass. Default and Dark are unchanged.

## Open

- Repo/org name on GitHub (e.g. `amatsubame/amatsubame` or `amatsubame-app`); the website is amatsubame.com.
