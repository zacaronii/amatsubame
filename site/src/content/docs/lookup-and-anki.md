---
title: Lookup and Anki
description: The popup dictionary every app shares, the dictionaries behind it, word marks, and making Anki cards through AnkiConnect.
---

Every Amatsubame app uses the same dictionary lookup and the same popup, so a word looks the same in
a manga, a subtitle, a podcast transcript or a web page. Cards go to your own Anki through
AnkiConnect.

## Looking up a word

Tap a word to open the popup:

- **Yomu:** a word in a book, or a speech bubble on a manga page once
  [text recognition](/yomu/) is set up.
- **Miru:** a word in the Japanese subtitles.
- **Kiku:** a word in the transcript.
- **Hiku:** Japanese text on any web page in Safari.

On a Mac, an iPad, or an iPhone held sideways, the popup opens as a card right by the word: below it,
or above it for subtitles near the bottom, and beside it in vertical text and manga. On an iPhone held
upright it slides up from the bottom; drag its top edge up to see more, or down to close it. Either way
what's behind shows through it, blurred (see **Background opacity** below). With a popup
open, tap another word to look it up straight away, or tap somewhere with nothing to look up (a
margin, a space, punctuation) or press Esc to close it.

The lookup finds the longest word that starts where you tapped, including conjugated forms, so
食べられなかった finds 食べる. Yomu also has a **Dictionary** tab where you can type a search (romaji
works too).

### What the popup shows

For each result, top to bottom:

- **The word** with furigana over its kanji, and, with **Show Brief Definitions Beside the
  Headword** on, its first few meanings next to it ("guilt-free · sinless · innocent").
- **How it was conjugated**, when the tapped text was an inflected form.
- **Frequency**: how common the word is, from each frequency dictionary you have. The first result
  also says how often you've looked it up ("Looked up 3 times").
- **Pitch accent**: a graph of the reading with the downstep number, from your pitch accent dictionary.
- **Definitions**, grouped under each dictionary's name, in your dictionary order.

Two buttons sit beside the word: the speaker plays **word audio**, and **+** (Add to Anki) makes a
card. It turns into a check mark for words you've already mined.

Tap a word inside a definition to look that up too; **Back** returns to the word before.

### Lookup counts

Each lookup adds one to the count of the first result's word, the dictionary form rather than the
form you tapped, so 食べた and 食べさせる both count for 食べる. A tap, a word tapped inside a
definition and a search you settle on each count once; going **Back**, or searching as you type,
doesn't. The counts work like [Hachidori](https://github.com/bee-san/hachidori)'s, and apps that share
their setup add to the same counts.

Settings ▸ Lookup and Mining ▸ **Popup** turns them off (your past counts are kept) or resets them.

### Background opacity

The popup is like frosted glass: what's behind it is always blurred. Settings ▸ Lookup and Mining ▸
**Popup** ▸ **Background Opacity** sets how much of the popup's colour lies over that blur, from 0 to
100% (85% by default, as in Hachidori): the lower it is, the more of the page, video or transcript
shows through. The text always stays solid, and at low opacity it gets a soft halo (dark in dark mode,
light in light mode) so it stays readable over anything; the halo fades out as the opacity goes up.

### Brief definitions

Settings ▸ Lookup and Mining ▸ **Popup** ▸ **Show Brief Definitions Beside the Headword** puts a
word's first few meanings next to it, so several results are quick to scan; the full definitions
stay below. As in Hachidori, a new installation starts with it on and two snippets (1–6 under
**Snippets**); setups from before version 0.3.0 keep it off until you turn it on. The snippets come
from the first dictionary that has a definition, or from the **Summary Dictionary** you choose, picked
the same way as Hachidori's.

### Word audio

Word audio comes from the sources in **Settings ▸ Lookup and Mining ▸ Audio Sources**. JapanesePod101
is built in. You can add your own, of two types:

- **Audio file URL**: an address that returns an audio file, with `{term}` and `{reading}` filled in
  for each word.
- **Audio list (JSON)**: an address that returns Yomitan's audio list, such as a local audio server,
  for example `http://audio.example.com:5050/?term={term}&reading={reading}`.

Sources are tried in order and the first one with audio plays. **Test with 食べる** checks them. If a
source's address contains a key, the key is hidden on screen and kept in the Keychain.

## Dictionaries

Dictionaries are stored on your device and work offline. The apps use the Yomitan dictionary format,
so most dictionaries made for Yomitan can be imported.

### The recommended set

Setup downloads [Hachidori](https://github.com/bee-san/hachidori)'s default dictionaries for you (about
105 MB in all):

| Dictionary | What it's for |
| --- | --- |
| Jitendex | English definitions |
| JMnedict | Names of people and places |
| Bee's Ultimate Kanji Dictionary | Kanji meanings, readings and stroke order |
| Jiten Frequency | How common each word is in anime, novels and games |
| Bee's Ultimate Grammar Dictionary | Grammar points, with examples |

**Kanjium** (pitch accent) is offered too, unticked: Hachidori's set has no pitch accent dictionary,
so tick it if you want the pitch graph in the popup and the pitch fields on your cards.

Each keeps its own licence; they're listed in **Settings ▸ About**.

### Managing dictionaries

Open **Settings ▸ Lookup and Mining ▸ Dictionaries**:

- **Installed** lists each dictionary with what it holds (Terms, Frequency, Pitch, Kanji), its size,
  and a switch to turn it off without deleting it. Results follow this order: on iPhone and iPad tap
  **Edit** and drag; on the Mac drag a row by its handle or right-click it. On iPhone and iPad, swipe a
  dictionary to delete it.
- **Sort Results By** picks which frequency dictionary orders the results. **Automatic** is the
  default.
- Longer matches come first. One exception when you tap text: a name from JMnedict that only matched
  by reading hiragana as katakana (たと as the name タト) goes after the other results. Searching for
  a name still finds it first.
- **Add Recommended…** installs any of the recommended set you don't have.
- **Import from Files…** imports Yomitan dictionary zips: term dictionaries, frequency lists and pitch
  accent dictionaries.
- **Import from URL…** downloads a zip from an address you type and imports it.

### Updates

The recommended dictionaries keep themselves up to date while **Keep Recommended Up to Date** is on
(in the Updates section; setup calls it Keep Them Up to Date). Dictionaries that update themselves
show **Auto**.

- The apps check once a week, and only on Wi-Fi outside Low Data Mode. **Check Now** checks straight
  away.
- A new version downloads in the background and replaces the old one when it's ready, keeping its
  place in your order and whether it's on.
- Imported dictionaries don't update unless their own files say they can and where from.
- If you delete a recommended dictionary, the apps remember and don't pick it again by themselves.

## Hachidori

If you use [Hachidori](https://github.com/bee-san/hachidori) in your browser and share it from a
computer or a Docker host, the apps can link to it: Settings ▸ Lookup and Mining ▸ **Hachidori**. Turn
on **Use Hachidori** and enter the address of the computer sharing it (port 8771 unless you changed
it).

### Copying Hachidori's dictionaries

While linked, Settings ▸ Lookup and Mining ▸ **Dictionaries** ▸ **Copy from Hachidori** lists
Hachidori's dictionaries and whether each is new to this device, newer than the copy here, or the
same. Tap **Copy** to download what's new or newer, at exactly Hachidori's versions (a dictionary you
pinned to an older release stays on that release), then match Hachidori's order and which ones are
on. Dictionaries that are only on the device stay, after Hachidori's.

- Hachidori sends its own ready-to-use copies, about two to five times the size of the dictionary
  files: its five recommended dictionaries take about 340 MB. Nothing downloads until you tap Copy.
- Copies don't update themselves; copy again after updating them in Hachidori.
- A dictionary made by a newer version of Hachidori's engine than the app has says so; update the app.

To add a dictionary file you import on a device to Hachidori too, turn on **Also Add Imports to
Hachidori** in the same section. Each zip you then import is sent to Hachidori after it's installed
here (replacing Hachidori's copy of the same dictionary). The apps don't keep the zip afterwards, so a
dictionary imported earlier has to be imported again to send it.

### Looking up on the Mac

While the Mac apps are linked:

- Words are looked up on Hachidori, with its dictionaries.
- Lookup counts are Hachidori's, so a word you look up in the browser and in Yomu counts twice in the
  same place.
- The popup follows Hachidori's settings (brief definitions, lookup counts, background opacity); the
  Popup page shows them but you change them in Hachidori.
- Words you marked known or ignored in Hachidori aren't underlined.
- Cards still go to your Anki through the apps' own Anki settings.

When Hachidori can't be reached, the apps look up with the Mac's own dictionaries and keep trying to
link in the background. Hachidori has no password, so only use it over your home network or a private
network such as Tailscale, never over the internet. The setting is shared by the apps that share a
setup. On iPhone and iPad the apps keep looking up with their own dictionaries, so lookups stay fast
and work anywhere; copy Hachidori's dictionaries to have the same ones.

## Word marks

With **Mark Words by Anki State** on (in Settings ▸ Lookup and Mining), the apps underline words by
where they stand in your Anki mining deck: words you haven't mined, and words you're still learning,
are underlined; words you know stay plain. A word counts as known once its card's interval is 21 days
or more. Cards waiting to be sent count as learning. Marks need Anki: until AnkiConnect is connected
they stay off, since every word would otherwise look unmined.

Marks show in Yomu's books (not on manga pages), Miru's subtitles, Kiku's transcripts and web pages
in Hiku. The apps refresh them from Anki when they open and every 30 minutes after that.

If you also study from other decks (a premade vocabulary deck, say), add them in the Anki settings
under **Word Marks ▸ Also Mark Words From**. Words you've started studying in those decks show as
known.

## Anki

### Connecting AnkiConnect

Cards go to Anki through [AnkiConnect](https://ankiweb.net/shared/info/2055492159), an add-on that
runs inside Anki on a computer or server. Your iPhone, iPad or Mac needs to reach it over the network,
for example at home or through a VPN.

:::note
By default AnkiConnect only accepts connections from the computer it runs on. Its `webBindAddress`
setting (in the add-on's config in Anki) controls which addresses it listens on.
:::

Open **Settings ▸ Lookup and Mining ▸ Anki** (or the Connect Anki step in setup):

1. Enter the **Server URL**, for example `http://anki.example.com:8765`.
2. If you set an `apiKey` in AnkiConnect's config, enter the same key. Otherwise leave it blank.
3. Tap **Test Connection**.

### Deck, note type and fields

Once connected, the same page has the **Cards** section:

- **Deck** and **Note Type**, from your Anki. The default deck is `日本語::Mining`.
- **Fields**: what goes into each field of the note type. Each field can hold nothing, one of the
  pieces below, or fixed text. **Reset to Default** puts the preset back.
- **Tags**, separated by spaces. The default is `amatsubame`.
- **Picture size**, the longest side of the card's picture (not in Miru, which has its own Card
  Picture setting).

The pieces a field can hold are: Word, Word with furigana, Reading, Word audio, Main definition, Short
definition, All definitions, Sentence, Picture, Sentence audio, Pitch accent, Pitch category,
Frequencies, Frequency sort value and Source.

**The Lapis preset.** With the [Lapis](https://github.com/donkuri/lapis) note type every field is
filled in the way Yomitan's Lapis setup does, and each card is a word and sentence card (the "x" in
`IsWordAndSentenceCard`):

| Lapis field | Gets |
| --- | --- |
| Expression | Word |
| ExpressionFurigana | Word with furigana |
| ExpressionReading | Reading |
| ExpressionAudio | Word audio |
| SelectionText | Short definition |
| MainDefinition | Main definition |
| Glossary | All definitions |
| Sentence | Sentence |
| SentenceAudio | Sentence audio |
| Picture | Picture |
| PitchPosition | Pitch accent |
| PitchCategories | Pitch category |
| Frequency | Frequencies |
| FreqSort | Frequency sort value |
| MiscInfo | Source |

For another note type, the apps fill in any Lapis field names it has; otherwise the word goes in the
first field and the sentence in a field called Sentence. Check **Fields** and adjust the rest.

### What a card contains

In every app a card can carry the word, its reading, definitions, pitch and frequency, and the
sentence it came from. The rest depends on the app:

| App | Sentence | Picture | Sentence audio | Source |
| --- | --- | --- | --- | --- |
| Yomu, manga | The recognised text | The page | | Series, chapter and page |
| Yomu, books | The sentence | The book's cover | With read-along: the spoken sentence | Series, volume and section |
| Miru | The subtitle line | A screenshot, or the line as an animated GIF (Card Picture) | The line | Show, episode and time |
| Kiku | The transcript line | The episode's cover | The line | Show, episode and time |
| Hiku | The sentence | | | The page's title and address |

Word audio is added when a field takes it and one of your audio sources has the word.

### Sending, undo and offline

After you tap **+**, the card waits five seconds so you can tap **Undo**, then goes to AnkiConnect. If a
word is already in Anki (or waiting to be sent), you're asked first and can choose **Add Another
Card**.

When AnkiConnect can't be reached (you're away from home, or the computer is asleep) cards wait on the
device and send themselves when it's back. The top of Settings shows what's waiting, with **Sync
Now**; **Settings ▸ Advanced ▸ Waiting to Sync** lists them by kind.

### Syncing to AnkiWeb

In the Anki settings, **Sync to AnkiWeb After Adding** asks Anki to sync about 10 seconds after new
cards arrive (once for a batch), so they reach AnkiMobile and your other devices. **Sync Anki Now**
syncs straight away.

## Sharing the setup between apps

Dictionaries, word audio sources, AnkiConnect (with its card settings), word marks, lookup counts and
the popup's settings can be shared
by Yomu, Miru, Kiku and Hiku on the same device, so you set them up once and a change in one app
shows in all of them. Servers, reading and watching progress, downloads, waiting cards and lookup
history always stay with each app.

When sharing is available:

- **Settings ▸ Advanced ▸ Share Setup with My Other Apps** turns it on or off. It's on by default.
- A newly installed app offers to reuse the shared setup during its first launch.
- Turning sharing off gives the app its own copy. A switch takes effect the next time the app opens.

Sharing uses an App Group, which on an iPhone, iPad or Mac needs a team in the paid Apple Developer
Program; a free account can't sign it. Builds for the Simulator share without it. Turning it on for
your devices takes a line in your signing settings and an App Group ID of your own, described in
[`docs/shared.md`](https://github.com/zacaronii/amatsubame/blob/main/docs/shared.md) in the
repository. Without it every app keeps its own setup, and Hiku's extension uses dictionaries built
into it (see [Hiku](/hiku/)).
