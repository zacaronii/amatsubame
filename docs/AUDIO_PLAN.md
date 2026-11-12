# Kiku (audio app) + Kaku (transcriber) — Design

Written 2026-11-03 and kept as design history, with each milestone's outcome. What was built is described in [kiku.md](kiku.md), [kaku.md](kaku.md) and [yomu.md](yomu.md).

## Summary

Add Audiobookshelf to the project in three parts: a transcriber container, **Kaku**, on a GPU machine that turns Japanese podcasts and audiobooks into timed, sentence-split transcripts; a new audio app, **Kiku**, for podcasts and audiobooks with tap-to-look-up transcripts and mining; and **read-along** in Yomu, which plays an audiobook in sync with its EPUB, like Hoshi Reader's Sasayaki.

**Decisions made**

| Topic | Decision |
| --- | --- |
| Where audio lives | One audio app for all Audiobookshelf content: podcasts and audiobooks |
| Read-along | Yomu can optionally connect to Audiobookshelf; books with both an EPUB (Kavita) and an audiobook get read-along |
| Source of truth for listening position | Audiobookshelf. Both apps resume from the newer position, as Yomu already does with Kavita |
| Where transcripts come from | Kaku container (GPU). Publisher transcripts in the feed are used when present. Apple's on-device speech engine is a fallback only |
| What gets transcribed | Whole Audiobookshelf libraries, switched on per library (Japanese and English content usually live in separate libraries). Backlog included; storage is under 1 MB per hour of audio |
| Model | Whisper large-v3 (faster-whisper), chosen 2026-11-04 after the milestone 0 test on real Japanese podcasts |
| Pairings (EPUB ↔ audiobook) | Stored in Kaku, so both apps see them |
| Code location | Same repo: a new app target, a shared Audiobookshelf package, and the container in `Server/kaku` |
| Names | Kiku (聞く) for the audio app and Kaku (書く) for the transcriber (docs/NAMING.md) |

## Architecture

```
APPS                                                       YOUR SERVER
+-------------+      streams audio, syncs progress      +----------------+
| Kiku        |---------------------------------------->| Audiobookshelf |<--+
+-------------+                                         +----------------+   |
      |  transcripts      +---------------------+  new items, audio ^       |
      +------------------>|      Kaku (GPU)      |-------------------+       |
      +------------------>| transcribes, aligns  |-------------------+       |
      |  pairs, alignments+---------------------+  EPUBs to align   v       |
+-------------+                                         +----------------+   |
| Yomu        |---------------------------------------->| Kavita         |   |
+-------------+      EPUBs, reading progress            +----------------+   |
      |                                                                      |
      +---------------- audio + progress for read-along ---------------------+
```

The apps talk to Audiobookshelf and Kavita directly for media and progress, as today; Kaku adds text and timings. Mined cards still go through each app's outbox to AnkiConnect (not drawn).

## Kaku (server container)

A Python container on a GPU machine that keeps every enabled Audiobookshelf library transcribed and serves the results over a small HTTP API.

**Finding work.** Poll the Audiobookshelf API every few minutes for new items and episodes in enabled libraries, using an Audiobookshelf API key (requires Audiobookshelf 2.26.0 or newer). Transcripts are keyed by Audiobookshelf item and episode IDs, the same IDs the apps use.

**Queue.** One GPU worker, one job at a time (so it doesn't starve other GPU work, such as Jellyfin transcoding on the same card). Priorities:

1. **Now:** an app asked for a transcript because you pressed play on an episode without one.
2. **New:** newly added episodes and books, oldest first.
3. **Backlog:** everything else in enabled libraries.

**Pipeline per item**

1. Fetch the audio and convert it to 16 kHz mono with FFmpeg.
2. Voice detection to skip music and silence (the main defense against invented text during intros and ad breaks).
3. Transcribe in Japanese with Whisper large-v3 (chosen in milestone 0; the model stays switchable in config). A punctuated Japanese `initial_prompt` is needed, or large-v3 writes almost no 。.
4. Word-level timings: faster-whisper's own. Forced alignment (wav2vec2, WhisperX-style) was compared on 10 sentence clips in milestone 1 (2026-11-05); there was no audible difference in most of them, so it was left out.
5. Re-split into sentences on 。！？ and long pauses, using word timings, so a mined sentence is a real sentence. Milestone 0 showed this isn't enough: large-v3 still leaves some lines over 20 s, so long lines are cut at their longest pause or a clause ending (、 plus a pause, 〜けど, 〜よね), only at word boundaries, aiming for about 15 s at most, and one-word fragments are merged into a neighbour.
6. Drop known hallucination patterns (repeated lines, text in no-speech regions) and store a confidence score per sentence.
7. Save JSON and a `.vtt` copy.

**Transcript format (JSON)**

| Field | Contents |
| --- | --- |
| `item` | Audiobookshelf item ID, episode ID (podcasts), library ID |
| `source` | Audio fingerprint, duration, model name and version, created time |
| `sentences[]` | `start`, `end` (seconds on the item's timeline), `text`, `confidence`, `words[]` |
| `words[]` | `text`, `start`, `end`, `confidence` |

Audiobooks made of several files use Audiobookshelf's single continuous timeline, so positions match what the apps report as progress.

**Re-runs.** If the audio fingerprint or the configured model changes, the item is re-queued and its transcript replaced, never duplicated.

**HTTP API** (behind HTTPS or a VPN; bearer token)

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/transcripts/{itemId}` and `/transcripts/{itemId}/{episodeId}` | Transcript JSON, or `202` with queue status if pending |
| POST | `/jobs` | Ask for an item now (top priority) |
| GET | `/jobs` | Queue and progress |
| GET, PUT | `/libraries` | Which Audiobookshelf libraries are enabled |
| GET, PUT, DELETE | `/pairs` | EPUB ↔ audiobook pairings (milestone 5) |
| GET | `/alignments/{pairId}` | Sentence timings mapped to EPUB positions (milestone 5) |
| GET | `/health` | Version, model, GPU status |

**Config** (environment variables): Audiobookshelf URL and API key, Kavita URL and auth key (for EPUBs in milestone 5), the API token, the model name, and the poll interval.

**Storage.** A volume holding a SQLite database (jobs, pairings, library switches) and the transcript files. About 1 MB or less per hour of audio.

## Kiku (the audio app)

A fourth app for everything in Audiobookshelf, built from the existing shared packages: lookup, mining, the outbox, and Miru's transcript (Lines) components.

**Library and playback**

- Sign in to Audiobookshelf; browse libraries, podcasts, episodes and books; continue-listening shelf.
- Audio playback with speed, skip intervals, chapters (books), sleep timer, Lock Screen and AirPods controls, background audio.
- Downloads for offline listening; transcripts are downloaded with the audio.
- Progress: report to Audiobookshelf through the outbox, offline-safe; on open, resume from the newer of local and server positions.

**Transcript view**

- Follows playback: the current sentence is highlighted and scrolls into view; tap a sentence to jump there.
- Tap a word to pause and open the shared lookup popup.
- While a transcript is pending, show its queue status and offer "Transcribe now" (asks Kaku for top priority).
- Fallbacks when Kaku has nothing: a publisher transcript from the feed (`<podcast:transcript>`), then Apple's on-device speech engine (iOS 26) on request.
- Edit a sentence's text before mining (fixes transcription mistakes).
- Search across all transcripts, reusing Miru's transcript search.

**Mining**

- Card fields: sentence, sentence audio (cut from the word timings, with a little padding), episode or book artwork as the picture, and the show, episode and timestamp as the source.
- Same Lapis preset, duplicate marking and outbox as the other apps.

**Mark now, mine later** (prototype first)

- One action marks "what I just heard": a Lock Screen bookmark button first; AirPods and CarPlay later if it proves useful.
- A mark saves the last ~15 seconds of the timeline, not a single line, because you always react after the line ends.
- A Marks list shows each mark's sentences with audio; pick the exact sentence, then mine as usual.
- Marks are stored locally and survive offline listening.

**Paired books** (after milestone 5): a paired audiobook's transcript shows the book's real text instead of the model's, plus an "Open in Yomu" button that opens Yomu at the same sentence.

## Read-along in Yomu

Yomu gets an optional Audiobookshelf connection. For a book that exists both as a Kavita EPUB and an Audiobookshelf audiobook, it plays the audio in sync with the text, like Hoshi Reader's Sasayaki.

**Pairing.** Yomu suggests matches by title (and author where available); you confirm, or pick manually. The pair is saved to Kaku's `/pairs` endpoint, so Kiku sees it too.

**Alignment (Kaku).** Once a pair exists, Kaku:

1. Downloads the EPUB from Kavita and extracts its text **using the same rules Yomu uses** (ruby/furigana stripped the same way, same chapter order, same notion of a character offset).
2. Matches its own transcript of the audiobook against the book's text: a fuzzy, character-level match after normalizing both sides (kana/kanji differences, numbers, punctuation). Front matter or appendices that aren't narrated are skipped.
3. Outputs, per book sentence: its EPUB position (chapter file + character offsets, in Yomu's addressing) and its start/end time on the audiobook timeline, plus a match score.

The position format is the one contract that must not drift. Claude Code should define it from Yomu's existing text index and share it with Kaku as a documented schema with fixtures, tested on both sides.

**In Yomu**

- Play/pause, speed and skip controls in the reader chrome.
- The current sentence highlights; pages turn automatically to follow the audio.
- Tap a sentence to move the audio there.
- Mining from a highlighted sentence includes its audio clip.
- Progress: listening drives both servers. Audiobookshelf gets the audio position; Kavita gets the matching page. Opening the book resumes from whichever moved last.
- Offline: read-along works with a downloaded book and downloaded audio.

## Shared code and repo layout

Everything stays in the one repo. New pieces, next to the existing `Packages/` (Anki, AppCommon, Core, Dictionary, JellyfinKit, JimakuKit, KavitaKit, Lookup, OCR, Player, Readers, Browser):

| New piece | What it holds | Used by |
| --- | --- | --- |
| Audiobookshelf package (like KavitaKit/JellyfinKit) | API client, auth, library/item/episode models, progress sync, fixture tests | Kiku, Yomu |
| Transcript package | Transcript JSON models, Kaku API client, local cache, the EPUB position contract | Kiku, Yomu, possibly Miru |
| Kiku app target | App, tests and UI tests folders, like `Miru/` | — |
| `Server/kaku` | Python service, Dockerfile, compose example, its own tests | Server |

Miru's transcript view and search (Lines) are the closest existing code to Kiku's transcript view. Claude Code should decide whether to move those into a shared package or reuse them where they are, rather than duplicating them.

Kaku is Python because the speech models are. It has its own test suite and a `docker compose` setup with a GPU profile; CLAUDE.md gets its commands next to the Xcode ones.

## Milestones

Each milestone runs in order and ends with something testable; milestone 0 decides the model before anything is built on it.

0. **Model test.** A throwaway script (in `Server/kaku`) that transcribes 3–4 real Japanese podcast episodes with both Kotoba-Whisper v2 and Whisper large-v3, with word timings and sentence splitting, and writes side-by-side output plus timing per hour of audio.
   - Done when: both have been compared on real episodes and a model picked; the GPU's speed per hour of audio is known.
   - **Done 2026-11-04: Whisper large-v3.** Four episodes (about 2½ h: a solo studio show, a casual two-person chat, an outdoor recording with wind, a fast tech talk), both models through faster-whisper with the same settings (beam 5, voice detection, word timestamps) on a 16 GB RTX 50-series card:

     | | large-v3 | Kotoba-Whisper v2 |
     | --- | --- | --- |
     | Speed | 17–20× real time (about 3–3½ GPU-minutes per audio hour) | 42–52× (about 1¼ min) |
     | GPU memory, whole card | about 5 GB peak | about 3 GB |
     | Text per minute | baseline | 16–27% less on every episode: mostly skipped speech |
     | Mean word confidence | higher on every episode | lower |

     Kotoba also misheard more (グーグルフォーム for グーグルホーム) and looped phrases on the noisy episode; on the clean studio episode the two were nearly identical. Caveat: Kotoba ran through faster-whisper's long-form decoding, not its recommended chunked Hugging Face pipeline. Also looked at, not tested: Kitsune-Transcribe (2026-10, pruned and distilled Cohere/Parakeet models), better than large-v3 on short clips but by its own README clearly worse on spontaneous long-form speech, with no word timings and non-commercial weights.
   - Notes for milestone 1: Kotoba-Whisper v2's faster-whisper config lists large-v3's alignment heads for a 2-layer decoder and crashes word timestamps (fix: `alignment_heads` = layer 1, heads 0–19); PyAV 16 breaks faster-whisper 1.2.1 (pin `av<16`); RTX 50-series (Blackwell) cards need CUDA 12.8+. The test's audio, outputs and image were deleted afterwards.
1. **Kaku for podcasts.** Polling, per-library switches, queue, pipeline, storage, HTTP API, Docker with GPU.
   - Done when: a new episode in a Japanese library gets a transcript automatically; English libraries are ignored; `POST /jobs` jumps the queue.
   - Running since 2026-11-05 (docs/kaku.md), with a podcast library switched on: its backlog was queued, `POST /jobs` moved the last episode to the front, and book libraries were refused (until milestone 4). Forced alignment was tested and left out (no audible difference). Done 2026-11-05: a newly added show's episode was queued as new and transcribed about two minutes after Audiobookshelf downloaded it.
2. **Kiku: podcasts.** Audiobookshelf package, library and playback, progress through the outbox, transcript view, lookup, mining with sentence audio, downloads.
   - Done when: a podcast sentence mined while offline reaches Anki with correct audio after reconnecting, and progress matches in Audiobookshelf's web UI.
   - Built 2026-11-05 (docs/kiku.md), following the design notes: no Lines tab (the transcript is in the player), Marks ships with transcript search, line jumps instead of on-screen skips, the system mini player. Done 2026-11-05: an episode downloaded and played offline, a sentence mined offline reached Anki with its 6-second clip after reconnecting, and progress matches Audiobookshelf's web UI. Offline the library shows its last saved copy and the downloaded episodes.
3. **Mark now, mine later (prototype).** Lock Screen bookmark, 15-second capture, Marks list.
   - Done when: it has been used on a few real listening sessions and judged worth keeping, changing or dropping.
   - Built 2026-11-05 (docs/kiku.md): marks from the Action Button / Siri ("Mark in Kiku", an App Intent, no extension), and the player (Now Playing's bookmark was tried; iOS 26 doesn't show it); the Marks tab plays each mark's 15 s, shows the likely line, and mines from it. The verdict was still open when milestone 6 was built.
4. **Kiku: audiobooks.** Books, chapters, sleep timer, multi-file timelines, book transcripts.
   - Built 2026-11-05 (docs/kiku.md, docs/kaku.md): Kaku 1.3 transcribes book libraries (multi-file books joined on Audiobookshelf's timeline; a 6.6 h book in about 25 minutes) and cuts clips for streamed audio (`/clips`); Kiku has Audiobooks in the Library, book pages with chapters, chapters in the player, book progress, downloads and mining. Kiku plays single-file books only for now; multi-file playback comes later.
5. **Read-along.** Pairing, the EPUB position contract, alignment in Kaku, read-along in Yomu, two-server progress.
   - Done when: on a paired book, highlights stay on the spoken sentence through a whole chapter, and listening in Kiku moves Yomu's place.
   - Built 2026-11-05 (docs/yomu.md), with one design change: the book text is matched to the transcript **in Yomu, on the device**, from the text runs its own reader shows, so there's no position format shared with Python (Kaku's `/pairs` and `/alignments` aren't built; pairs live in Yomu until Kiku needs them). On the test novel 82% of sentences matched; opening it in Yomu went to the sentence Kiku had reached, and the highlight followed the audio across page turns.
6. **Polish and extras.** "Open in Yomu" from Kiku, AirPods/CarPlay marks if milestone 3 earned them, optional Japanese subtitles for Jellyfin episodes that Jimaku lacks.
   - Built 2026-11-06, all of it before the milestone 3 verdict:
     - **Read in Yomu:** Kiku opens Yomu through a link carrying the time (docs/kiku.md, docs/yomu.md).
     - **AirPods marks:** a triple press marks, with a chime; a double press goes to the next line. CarPlay as an app needs Apple's approval, but its Now Playing and steering-wheel buttons send the same commands.
     - **Kaku 1.4** transcribes Jellyfin episodes on request with its own Jellyfin API key, and Miru's Subtitles sheet asks for them (docs/kaku.md, docs/miru.md). Jellyfin items share the queue as `jf:<id>`, rather than adding a source column.
     - **Shared client:** `KakuClient` stays in AudiobookshelfKit. It needs that package's paths, and Miru already linked it through AppCommon.
   - Also fixed: #57 (the screen dims during playback).

## CLAUDE.md cleanup

Done 2026-11-03 (CLAUDE.md is now about 70 lines): area notes are in `docs/yomu.md`, `docs/miru.md`, `docs/hiku.md` and `docs/shared.md`, and contributor-specific details in an optional gitignored `CLAUDE.local.md`. Kaku's commands get added once `Server/kaku` exists.

Do this before milestone 1, since the new work adds a Python service and a fourth app to the same file. CLAUDE.md is about 25 KB and loads in full every session; most of it is detailed notes that only matter when working on one area.

- [x] **Remove stale sections:** the original "First prompt" (Phase 0) at the end, and a stale line about the AnkiConnect API key.
- [x] **Move area notes out:** the long run of Player, Jimaku, subtitle and media-segment notes now sitting under "Commands" becomes per-area docs (now `docs/yomu.md`, `docs/miru.md`, `docs/hiku.md`, `docs/kiku.md`, `docs/kaku.md` and `docs/shared.md`). CLAUDE.md keeps one line per area pointing to its doc, so Claude Code reads them only when working there.
- [x] **Split out personal details** into a gitignored local file loaded alongside CLAUDE.md: device IDs, local folder paths, and the specifics of one person's servers (library layout, plugins, rules for uploading test subtitles to a live library). This also prepared the repo for going public.
- [x] **Add a short project map:** the four apps, the packages and what each owns, and `Server/kaku`.
- [x] **Add Kaku's commands** (run tests, build the image, run with compose) next to the Xcode ones.
- [x] **Keep in CLAUDE.md:** the rules (outbox for all writes, one shared lookup, Keychain, keep every target building), the issues workflow, and the commands.

Target: CLAUDE.md under about 150 lines, with everything else one link away.

## Open questions

- [x] Names: Kiku and Kaku (docs/NAMING.md).
- [x] Audiobookshelf version: developed against 2.36.1; API keys need 2.26.0 or later.
- [x] GPU memory: large-v3 peaks at about 5 GB, so a 16 GB card has room beside other GPU work (Jellyfin transcoding uses a few hundred MB); one job at a time is still the rule.
- [x] How Kaku is reached from the phone: over HTTPS on the local network or through a VPN, with a bearer token.
- [x] Which 3–4 podcast episodes to use for the milestone 0 model test: four, of different recording styles (chosen 2026-11-04).

## Sources

- [Kotoba-Whisper v1.0 model card](https://huggingface.co/kotoba-tech/kotoba-whisper-v1.0) and [v2.0 for faster-whisper](https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-faster)
- [WhisperX guide (word-level alignment)](https://localaimaster.com/blog/whisperx-guide)
- [Apple SpeechAnalyzer languages](https://blog.addpipe.com/apple-speechanalyzer-api/)
- [Audiobookshelf API docs](https://api.audiobookshelf.org) and [API keys requirement (2.26.0+)](https://socket.dev/npm/package/audiobookshelf-mcp)
- [Podcast feed transcript tag adoption](https://jwatte.com/blog/blog-tool-podcast-feed-audit/)
- [Hoshi Reader / Sasayaki (via hibiki's credits)](https://github.com/hajisensai/hibiki/wiki)
