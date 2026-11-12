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

A round, cute Pacific swift, drawn true to life: greyer head fading to a blackish body, a long near-black scythe wing laid along its side with a lighter front edge, a broad white rump band, a pale throat that wraps up around a small black bill (the bill has a pale edge so it shows on any background), three faint belly scallops, a deep forked tail, dark eyes with a sparkle, and pink blush. Each app keeps its gradient and one prop.

| App | Icon | Background gradient (150°) | Prop outline (light) | Prop outline (dark) |
| --- | --- | --- | --- | --- |
| Yomu | Swift over an open book | `#D4F27A` → `#3FC98F` → `#0A8FA0` | `#0B4F45` | `#5FE0A8` |
| Miru | Swift in front of a white screen frame | `#D99BEF` → `#AA5CC3` → `#0098D6` | white frame | white frame |
| Kiku | Swift with eyes closed, headphones on both sides of its head | `#FFE27A` → `#F79A3E` → `#E2513A` | `#6B2410` | `#FFAE5C` |
| Hiku | Swift in profile, looking through a magnifying glass | `#FF9CC0` → `#EE4F6B` → `#9E1F5E` | `#5E0F32` | `#FF7597` |

Files are in `Design/icons/<App>/`, all on a 100 × 100 viewBox:

- `<App>-background.svg`: the gradient (unchanged from the lyrebird icons).
- `<App>-background-dark.svg`: Dark mode's background: a dark grey gradient (`#3A3A40` → `#101012`) with a soft glow of the app's middle color rising from the bottom.
- `<App>-foreground.svg` (+ `-1024.png`): the bird and prop on transparency, for Default.
- `<App>-foreground-dark.svg` (+ `-1024.png`): the same, with lighter greys, a faint white rim around the body, wing and tail, and brighter prop outlines. Without it the black tail, wing and lower body vanish on a dark background. Use it for Dark only.
- `<App>-foreground-mono.svg` (+ `-1024.png`): a light-bodied swift for Tinted and Clear, where iOS turns everything into one color and the dark bird faded.
- `<App>-icon.svg` / `<App>-icon-1024.png`: the flattened Default icon for the asset catalog.
- `previews/<App>-<mode>.png`: an approximation of Default, Dark, Clear light and dark, and Tinted light and dark, to compare against Icon Composer's real rendering.

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
