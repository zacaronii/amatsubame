---
title: Getting started
description: What you need, how to build the apps from source with Xcode, and what the first launch walks you through.
---

The Amatsubame apps aren't on the App Store, so you build them yourself with Xcode and install them
on your own devices. That takes a few minutes once, and after that each app's first launch walks you
through connecting your server, choosing libraries and getting dictionaries.

## What you need

- **An iPhone, iPad or Mac** on iOS, iPadOS or macOS 26. Every app runs on all three; Hiku's
  extension runs in Safari on each of them.
- **A Mac with Xcode 26 or later**, to build the apps.
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**, which makes the Xcode project. The easiest way
  to install it is with [Homebrew](https://brew.sh).
- **At least one of your own servers**, for the apps you want to use:

  | App | Server |
  | --- | --- |
  | [Yomu](/yomu/) | [Kavita](https://www.kavitareader.com), for manga and books |
  | [Miru](/miru/) | [Jellyfin](https://jellyfin.org), for shows and films |
  | [Kiku](/kiku/) | [Audiobookshelf](https://www.audiobookshelf.org) 2.26.0 or later, for podcasts and audiobooks |
  | [Hiku](/hiku/) | None: it looks words up on any web page |

- **Optional:**
  - Anki with [AnkiConnect](https://ankiweb.net/shared/info/2055492159), reachable from your devices,
    to make cards. See [Lookup and Anki](/lookup-and-anki/).
  - [Kaku](/kaku/), the transcription server, on a machine with an NVIDIA GPU. Kiku needs it for
    transcripts, Yomu uses it for read-along, and Miru can ask it for subtitles.
  - A free [Jimaku](https://jimaku.cc) account, for Japanese subtitles in Miru.

## Build the apps

1. Get the code and install XcodeGen:

   ```sh
   git clone https://github.com/zacaronii/amatsubame.git
   cd amatsubame
   brew install xcodegen
   ```

2. Make the Xcode project and open it:

   ```sh
   xcodegen
   open Amatsubame.xcodeproj
   ```

   The project is made from `project.yml`, so run `xcodegen` again whenever you pull new code.

3. To run on your own devices, tell Xcode which Apple developer team signs the apps, and give the
   apps bundle IDs of your own (the default `com.amatsubame.*` IDs belong to another team). Create
   the file `Config/Signing.local.xcconfig`:

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   BUNDLE_ID_PREFIX = com.yourname.amatsubame
   ```

   Use your team ID and any reverse-domain prefix you like. The file is ignored by Git, so it stays
   on your Mac. Builds for the Simulator don't need it.

4. In Xcode, choose a scheme (**Yomu**, **Miru**, **Kiku** or **Hiku**) and a destination (your
   iPhone or iPad, or My Mac), then press Run. Repeat for each app you want.

:::note[With a free Apple account]
You can run the apps on an iPhone or iPad with a free Apple account, but installs made that way
expire after 7 days, and you run them from Xcode again to renew them. A free account also can't
sign the App Group that lets the apps share one setup, so each app keeps its own dictionaries and
Anki settings, and Hiku's extension uses dictionaries built into it. See
[Sharing the setup between apps](/lookup-and-anki/#sharing-the-setup-between-apps).
:::

Nothing large is bundled with the apps. Dictionaries download during setup, and Yomu downloads its
manga text recognition models when you ask for them in Settings.

## First launch

Yomu, Miru and Kiku open with a short setup the first time. Every step saves through the same
screens you'll find in Settings later, so nothing here is final. Hiku has no setup flow: its app shows
how to turn the extension on in Safari (see [Hiku](/hiku/)).

1. **Welcome.** What the app does and the three things ahead: connecting your server, getting
   dictionaries and (optionally) connecting Anki. Tap **Get Started**.
2. **Connect your server.**
   - Yomu: your Kavita address and an auth key (in Kavita, User Settings ▸ Auth Keys).
   - Miru: your Jellyfin address, username and password. Only a sign-in token is kept, never the
     password.
   - Kiku: your Audiobookshelf address, then either your username and password or an API key.
3. **Which libraries are Japanese?** A switch for each library on the server. Setup turns on the ones
   that look Japanese (by their names, and in Miru by their audio), and only the ones you leave on show
   in the app. You can change this later in Settings.
4. **Use your existing setup?** This appears only when another Amatsubame app on the same device has
   already shared its setup. **Use This Setup** reuses its dictionaries, Anki and word audio sources,
   and skips ahead to the extras. **Set Up Separately** gives this app its own; setup then asks you to
   close and reopen the app and carries on with dictionaries.
5. **Get dictionaries.** The recommended dictionaries start downloading straight away. You can continue
   once Jitendex (or another dictionary with definitions) is in. **Keep Them Up to Date** checks for
   new versions weekly on Wi-Fi. You can also import your own Yomitan dictionaries here.
6. **Connect Anki.** Your AnkiConnect address and, if you set one in AnkiConnect, its API key. Tap
   **Test** to check it. Choose **Skip, I don't use Anki** or **Later** to move on without it.
7. **Where should cards go?** Shown once Anki is connected: the deck, the note type and tags. The fields
   are filled in for you (the [Lapis](https://github.com/donkuri/lapis) note type has a ready-made
   preset); **Review Fields** shows what goes where.
8. **Extras.** Optional pieces, each opening its page in Settings and coming back here:

   | App | Extras |
   | --- | --- |
   | Yomu | Manga Text Recognition, Read-Along, kechimochi |
   | Miru | Jimaku, Kaku, kechimochi |
   | Kiku | Kaku, kechimochi |

9. **You're all set.** A checklist of what's ready and where anything you skipped waits in Settings.
   Tap **Start Reading**, **Start Watching** or **Start Listening**.

If you leave setup part-way, it opens again where you were next time.

### Skipping setup, and running it again

On the Welcome screen, **I'll set it up later** closes setup. The app shows nothing until its server
is connected, which you can do in Settings at any time.

To go through setup again, open **Settings ▸ Advanced ▸ Run Setup Again**. It shows your current
choices, and nothing is deleted.

:::tip
Set up one app fully first (dictionaries and Anki included). If your build can share the setup, the
next app you open offers to reuse it, so you only connect its own server.
:::

## Next steps

- Each app's guide: [Yomu](/yomu/), [Miru](/miru/), [Kiku](/kiku/), [Hiku](/hiku/).
- [Lookup and Anki](/lookup-and-anki/): the popup dictionary, dictionaries, word marks and cards.
- [Kaku](/kaku/): running the transcription server.
