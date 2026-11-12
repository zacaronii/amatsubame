# Kaku (the transcriber): working notes

`Server/kaku`, a Python 3.12 service in one Docker container on a machine with an NVIDIA GPU. It keeps the Japanese podcast and audiobook libraries in Audiobookshelf transcribed with Whisper large-v3 and serves the transcripts to the apps (Kiku, Yomu's read-along, and Miru's subtitles). The design is in [AUDIO_PLAN.md](AUDIO_PLAN.md). Kaku is MIT licensed (`Server/kaku/LICENSE`).

## Pieces (`Server/kaku/kaku/`)
- `audiobookshelf.py`: a GET-only client. Kaku never writes to Audiobookshelf. A poll refetches an item only when its `updatedAt` changed.
  - **Books** (1.3): a book is one job with an empty episode id. Its tracks (`media.tracks`, with `startOffset`) make Audiobookshelf's single timeline; the fingerprint joins every track's `ino:size:duration` with `+` (a podcast keeps the one-file form, so 1.2 transcripts weren't redone).
- `db.py`: SQLite (`/data/kaku.db`) with libraries (on/off), jobs and transcripts.
  - **Job priorities:** `now` (asked for with `POST /jobs`, in the order asked), then `new` (added in the last 7 days, oldest first), then `backlog` (newest first).
  - **Duplicates:** a job is keyed by item and episode, so an episode is never queued twice.
  - **Re-transcribing:** a changed audio file (fingerprint `ino:size:duration`, per track for books) or a different model queues the episode again, and the new transcript replaces the old one.
  - **Failures:** a failed job is retried after 10, then 20 minutes. After 3 attempts it stays failed until asked for again.
  - **Restarts:** a job left running is queued again.
- `poller.py`: every 5 minutes, and straight away when libraries are switched, it queues what's missing from the enabled podcast and book libraries. Libraries start off; switch on only the Japanese ones.
- `worker.py`: the one GPU worker, one job at a time.
  - **Steps:** download, FFmpeg to 16 kHz mono, transcribe, write `<episodeId>.json` and `.vtt` (`book.json` for a book) under `/data/transcripts/<itemId>/`, delete the audio.
  - **Books of several files:** each file is converted and padded or trimmed to its track's length, then joined with FFmpeg's concat, so times match Audiobookshelf's timeline. A 6.6 h single-file book took about 25 minutes on a mid-range consumer GPU.
  - **GPU memory:** the model loads on the first job (about 6 s, about 3.7 GB) and unloads after 10 idle minutes, giving the memory back to anything else on the GPU (Jellyfin's transcoding, say).
- `jellyfin.py` (1.4): a GET-only Jellyfin client, for Miru's subtitles when Jimaku has none. Jellyfin episodes are transcribed only on request (`POST /jellyfin/jobs`); nothing is polled.
  - **Keys:** a Jellyfin episode is the job `jf:<item id>` with an empty episode and library `jellyfin`, so the queue and storage are shared with Audiobookshelf's (`/data/transcripts/jf:<id>/video.json`).
  - **Audio:** the first audio track tagged Japanese (`jpn`/`ja`), else an untagged one. An episode whose audio is all in other languages is refused. FFmpeg reads the original file over HTTP (`/Videos/{id}/stream?static=true`, `-map 0:a:<n>`), with the key only in `-headers`; errors pass on only FFmpeg's last line.
  - **Fingerprint:** `<media source>:<size>:<ticks>:a<track>`.
  - **Lookup:** `/Items?ids=<id>&fields=MediaSources`, since Jellyfin 12.3's `/Items/{id}` needs a user with an API key.
  - **Prompt:** a plain conversational one instead of the podcast prompt (still punctuated, so 。、 come out).
  - **Settings:** `JELLYFIN_URL` and `JELLYFIN_API_KEY`, both optional (make a key for Kaku in Dashboard ▸ API Keys). Without them the routes answer `503`.
- `pipeline.py`: faster-whisper 1.2.1 in batched mode (batch size 8), with beam 5, voice detection, word timestamps and a punctuated Japanese prompt.
  - **Why batched:** it cuts the audio at speech pauses into independent chunks and gives each chunk the prompt.
  - **Why not sequential (milestone 0's mode):** with conditioning off, it used the prompt only for the first 30 s, so long episodes came out almost without 。. Batched is also 3–5× faster (30–45× real time).
  - **Why not `hotwords`:** it repeats the prompt every window, but it leaked the prompt's words into the text and lost speech.
  - **Pipeline version:** `PIPELINE` in `kaku/__init__.py` is part of a transcript's model key. Bumping it re-transcribes everything.
- `split.py`: sentences end at 。！？ and at pauses over 0.8 s.
  - **Long lines:** a line over 15 s is cut at its longest pause, where a clause ending (、, けど, よね, から…) counts as half a second of pause. Cuts fall only between words, and each part is at least 2 s.
  - **Whole words** (1.4.1): Whisper's Japanese "words" are its tokens, so a rare compound comes one kanji at a time (容 / 赦なく). A pause between two kanji, or after a number (94 / 円), doesn't split unless it's over 10 s, and a long line is cut there only if nothing else fits. Transcripts made before it can be split again with `kaku.resplit` (below). Since 1.4.2 the same goes for a pause before something no line starts with (を, small kana, ー, closing punctuation): a narrator's pause in 目 / を奪われた.
  - **Fragments:** a one-word fragment joins the nearer neighbour.
- `transcript.py`: drops hallucinations and writes the files.
  - **Dropped:** runs of 3 or more identical lines (the first is kept), sentences starting in a segment the model marks as no speech, and sentences that are one of the prompt's own.
  - **Kept with lower confidence:** a repetitive segment (compression ratio over 2.4) halves its sentences' confidence.
- `api.py`: FastAPI. `main.py` runs the poller and worker threads and serves on port 8000.

## API
Everything except `/health` needs `Authorization: Bearer <KAKU_API_TOKEN>`.

| Method | Path | Answer |
| --- | --- | --- |
| GET | `/health` | Version, model, whether it's loaded, GPU memory, job counts, last poll and its error, and whether Jellyfin is set up (1.4) |
| GET | `/transcripts/{itemId}/{episodeId}` | The transcript JSON (`?format=vtt` for WebVTT); `202` with the job (`state`, `priority`, `position`, `progress`) while waiting; `404` when Kaku knows nothing of it |
| GET | `/transcripts/{itemId}` | The same for a book (1.3) |
| POST | `/jobs` `{itemId, episodeId}` | Queues the episode first (`202` with its position), or `200` `{state: "done"}` when its transcript is current; `404` if Audiobookshelf has no such episode. Leave out `episodeId` for a book |
| POST | `/transcripts/status` `{episodes: [{itemId, episodeId}]}` | `{statuses: {"<item>/<episode>": done/queued/running/failed/missing}}` for badges, up to 2000 at a time (Kaku 1.2); a book (no `episodeId`) is keyed by its item id |
| GET | `/clips/{itemId}[/{episodeId}]?start=&end=` | A part of the audio as AAC `.m4a`, at most 60 s, for card audio while streaming (1.3). FFmpeg reads just that part of the file from Audiobookshelf (`-ss` with range requests; checked to the millisecond against the whole file). A clip stays within one file. About 0.5 s, even at hour 5 of a book |
| POST | `/jellyfin/jobs` `{itemIds: [...]}` | Queues Jellyfin episodes first, in the order given (1.4, at most 100). `{jobs: [{itemId, state, position?, progress?, error?}]}`, where `state` is done, queued, running or unavailable (not in Jellyfin, or no Japanese audio) |
| POST | `/jellyfin/transcripts/status` `{itemIds: [...]}` | `{statuses: {"<id>": done/queued/running/failed/missing}}` |
| GET | `/jellyfin/transcripts/{id}` | The transcript JSON, `?format=vtt` or `?format=srt` (SubRip, for Miru); `202` with the job while waiting; `404` when Kaku knows nothing of it |
| GET | `/jobs` | The running job with its progress, the queue (`?limit=`), counts and recent failures |
| GET, PUT | `/libraries` | Audiobookshelf's libraries (`id`, `name`, `mediaType`, `enabled`); PUT `{enabled: [ids]}` sets them all (the ones left out are switched off) and refuses unknown ids (`400`) |

**Transcript JSON:** the format from [AUDIO_PLAN.md](AUDIO_PLAN.md).
- `item`: `libraryItemId`, `episodeId`, `libraryId`.
- `source`: `fingerprint`, `duration`, `model`, `modelVersion`, `kaku`, `createdAt`.
- `sentences[]`: `start`, `end`, `text`, `confidence` and `words[]` (`text`, `start`, `end`, `confidence`), with times in seconds on the episode's timeline.

## Running it
Kaku needs a machine with an NVIDIA GPU and Docker with the NVIDIA Container Toolkit (the `nvidia` runtime). Whisper large-v3 takes about 3.7 GB of GPU memory while loaded (about 5 GB at peak). The image is built on `nvidia/cuda:12.8.1-cudnn-runtime` (RTX 50-series, Blackwell, cards need CUDA 12.8 or later), so the host's NVIDIA driver must support CUDA 12.8. It needs Audiobookshelf 2.26.0 or later (API keys).

1. In `Server/kaku`, copy `env.example` to `.env` (it's gitignored; keep it private) and fill it in:
   - `AUDIOBOOKSHELF_URL` as Kaku reaches it, and `AUDIOBOOKSHELF_API_KEY` (Audiobookshelf ▸ Settings ▸ API Keys).
   - `KAKU_API_TOKEN`: any long random string (`openssl rand -hex 32`); the apps send it with every request.
   - Optional: `JELLYFIN_URL` and `JELLYFIN_API_KEY` (an API key made for Kaku in Dashboard ▸ API Keys), for Miru's subtitles.
   - `KAKU_PORT` (default 8000) and `TZ`.
2. `docker compose up -d --build`. The database and transcripts go in `./data`, the Whisper model cache in `./models` (about 3 GB, downloaded on the first job).
3. Switch on your Japanese libraries: libraries start off, so English ones are never transcribed by accident. `GET /libraries` lists them; `PUT /libraries` with `{"enabled": [ids]}` sets them. Kaku then queues their backlog.
4. In each app, Kaku's address and the token: Kiku in Settings ▸ Listening ▸ Transcripts, Yomu in Settings ▸ Reading ▸ Read-Along ▸ Kaku, Miru in Settings ▸ Watching ▸ Subtitles ▸ Kaku.

- **Reaching it:** the compose file only publishes a plain-HTTP port. Before using it away from home, put it behind HTTPS (a reverse proxy) or a VPN such as Tailscale: the token is sent with every request, and nothing else protects the API.
- **Health check:** the image's Docker health check calls `/health` every minute, so a proxy that waits for healthy containers routes Kaku about a minute after it starts.
- **Other settings** (not in the compose file by default; add them under `environment:` to use them): `KAKU_MODEL` (default `large-v3`), `KAKU_POLL_SECONDS` (300), `KAKU_IDLE_UNLOAD_SECONDS` (600).
- **Tests** (no GPU needed): `python3 -m pytest -q tests` in `Server/kaku`, with fastapi, httpx and pytest installed. The tests use recorded Audiobookshelf and Jellyfin fixtures with every value replaced. Inside the image: `docker compose run --rm --no-deps kaku python3 -m pytest -q -p no:cacheprovider tests`.
- **Updating:** pull the new code, then `docker compose up -d --build` again. `./data` and `./models` are kept.
- **After the splitting rules change:** `docker compose exec kaku python3 -m kaku.resplit [--dry-run]` splits the saved transcripts again from their stored words (no GPU; changed ones get `source.resplit`). Back up `data/transcripts` first. Kiku replaces a saved transcript when an episode opens and Kaku's lines differ; Yomu's alignment keeps times, so it's unaffected; a Kaku subtitle Miru already saved stays as it was.

## Known limits
- **Speaker names:** some shows' transcripts get speaker names written into the text with no punctuation (for example `山田 いいね`), from Whisper's training data. Those lines split only at pauses.
- **Word timings:** these are faster-whisper's own. Forced alignment (wav2vec2, WhisperX-style) was compared on 10 clips cut both ways; there was no audible difference in most, so it isn't used. Aligned starts were 0.3–0.6 s later on average.
