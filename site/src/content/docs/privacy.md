---
title: Privacy
description: What the Amatsubame apps and Kaku keep, where it stays, and which outside services they contact and why.
---

**Effective 12 November 2026.**

Amatsubame is a set of apps you build yourself and connect to your own servers. In short: there's
nothing to sign up for with us, the apps don't collect anything about you, and nothing is sent to the
people who make them.

## What we collect

Nothing.

- There are no Amatsubame accounts. You sign in only to your own servers.
- The apps have no analytics, tracking, advertising or crash-reporting code.
- Nothing is sent to the developers, and there's no Amatsubame server for the apps to talk to.

## What stays on your device

Each app keeps its data in its own storage on your device: your settings, reading, watching and
listening progress, downloads, dictionaries, lookup history, saved transcripts and subtitles, Stats,
and cards waiting to be sent to Anki. If your build shares the setup between apps, the shared
dictionaries, word audio sources and Anki settings sit in a space only the Amatsubame apps can open.

Server keys and sign-in tokens are kept in the Keychain, not in the apps' files. When you sign in to
Jellyfin or Audiobookshelf with a password, the password is used once to sign in and isn't kept; the
app keeps the token the server gives back. Keys inside a word audio source's address are kept in the
Keychain too.

Each app also keeps a small log of server errors, syncing, dictionary updates and setup, with tokens,
keys and passwords blanked out. It stays on the device unless you share it yourself with **Export
Logs**.

## Your own servers

The apps talk to the servers you connect, at the addresses you enter, and nothing else of yours goes
anywhere else:

| Server | What the apps do there |
| --- | --- |
| Kavita (Yomu) | Browse and read your library, download what you ask for, save your reading progress |
| Jellyfin (Miru) | Browse and play your library, report what you watch, and upload a subtitle only when you choose **Save to Jellyfin…** |
| Audiobookshelf (Kiku, and Yomu's read-along) | Browse and play your podcasts and audiobooks, save your listening progress |
| Kaku | Fetch transcripts, subtitles and audio clips, and ask for an episode to be transcribed |
| AnkiConnect | Read your decks, note types and mined words, add the cards you make, and ask Anki to sync |
| kechimochi | Read your immersion totals for Stats (nothing is written to it) |
| Your own word audio sources | Fetch audio for a word |

Your cards hold what you mined: the word, the sentence and, depending on the app, a picture, an audio
clip and where it came from (in Hiku, the page's title and address). They go only to your AnkiConnect.
If Anki syncs to AnkiWeb, that's between Anki and AnkiWeb.

Kaku runs on your own machine. It reads audio from your Audiobookshelf and, if you set it up, your
Jellyfin, and keeps its transcripts on that machine. It downloads the Whisper model from Hugging Face
the first time it runs a job.

## Public services the apps may contact

A few things come from public services. Each is contacted only for the reason given.

| Service | Used by | When and why |
| --- | --- | --- |
| `assets.languagepod101.com` | All apps | Word audio from JapanesePod101, the built-in audio source (on unless you turn it off in Audio Sources). The word and its reading are sent when you play a word's audio, or make a card whose fields include word audio. |
| `github.com` | All apps | Downloading the recommended Jitendex, JMnedict, KANJIDIC and Kanjium dictionaries, from their publishers' GitHub releases (GitHub serves the files from its own download servers). |
| `api.jiten.moe` | All apps | Downloading the Jiten frequency dictionary. |
| Dictionary update addresses | All apps | Checking for new versions of a dictionary that names its own update address, weekly on Wi-Fi while updates are on. For the recommended set these are their publishers' addresses. |
| An address you type | All apps | **Import from URL…** downloads a dictionary from the address you give. |
| `huggingface.co` | Yomu | Downloading the manga text recognition models, only when you ask for them in Settings. Recognition itself runs on your device. |
| `jimaku.cc` | Miru | Searching for Japanese subtitles and downloading the file you pick, only after you add your own Jimaku API key. Miru sends the show's AniList number or its name, and your key. |
| `arm.haglund.dev` | Miru | Finding a show's AniList number from its AniDB number, when your Jellyfin library provides one, so Jimaku finds the right show. Only the AniDB number is sent. |

Dictionaries are downloaded once and then used offline: looking a word up never leaves the device.

## Hiku in Safari

Hiku's extension can run on any page, because you might tap Japanese text anywhere. It reads the text
around the place you tap to look the word up. With word marks on, it also reads the paragraphs near
where you're reading, to underline words by their state in Anki; it draws the marks over the page
without changing the page itself. All of this is handled on your device by Hiku itself. Hiku doesn't keep a
record of the pages you visit or send them anywhere; the only time a page's title and address leave the device is on a
card you make, which goes to your own AnkiConnect.

## Your choices

- Each outside service above is used only for the feature it serves: turn off the JapanesePod101
  audio source, skip the downloads, or leave Jimaku unset, and it isn't contacted.
- Deleting a dictionary or a download removes it from the device.
- On iPhone and iPad, deleting an app removes its own data with it.

## Changes and contact

If this changes, this page will be updated and its date changed. Questions about privacy are welcome
as an issue on [GitHub](https://github.com/zacaronii/amatsubame/issues).
