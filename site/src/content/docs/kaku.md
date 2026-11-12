---
title: Kaku
description: Run Kaku, the Whisper transcription server that gives Kiku its transcripts, Yomu its read-along and Miru subtitles on request.
---

**Kaku** (書く, to write down) is a small server you run on a machine with an NVIDIA GPU. It keeps
the Japanese podcast and audiobook libraries in your Audiobookshelf transcribed with Whisper large-v3
(through [faster-whisper](https://github.com/SYSTRAN/faster-whisper)), and hands the apps timed
transcripts split into sentences:

- **[Kiku](/kiku/)** shows the transcript line by line as you listen, and you tap words in it. Without
  Kaku, episodes play without their text.
- **[Yomu](/yomu/)** uses the transcript to match an audiobook to its EPUB for read-along.
- **[Miru](/miru/)** can ask Kaku for Japanese subtitles when Jimaku has none. Jellyfin episodes are
  transcribed only when you ask, never on their own.

Kaku only reads from Audiobookshelf and Jellyfin; it never changes anything on them.

## What it does on its own

- Every 5 minutes (and straight away when you change which libraries it covers), Kaku looks for
  podcast episodes and audiobooks that don't have a transcript yet and queues them.
- It works through one at a time. What you ask for in an app comes first, then episodes added in the
  last week, then the rest of the backlog, newest first.
- For each one it downloads the audio, transcribes it, saves the transcript and deletes the audio.
- If an episode's audio file changes, it's transcribed again. A failed job is retried twice, then
  waits until something asks for it again.
- Whisper loads on the first job and is unloaded after 10 minutes with nothing to do, giving the GPU
  memory back to anything else that uses it.

As a rough guide, on a mid-range consumer GPU a 24-minute episode takes about 30 seconds and a
6.6-hour audiobook about 25 minutes.

## Requirements

- **An NVIDIA GPU** with about 4 GB of free memory while Kaku works (about 3.7 GB with the model
  loaded, up to about 5 GB at peak).
- **An NVIDIA driver that supports CUDA 12.8.** The image is built on CUDA 12.8, which RTX 50-series
  (Blackwell) cards need.
- **Docker with the NVIDIA Container Toolkit**, so containers can use the `nvidia` runtime.
- **Audiobookshelf 2.26.0 or later**, with an API key for Kaku. Kaku needs it even if you only want
  Miru's subtitles.
- **Optional: Jellyfin**, with an API key for Kaku, for Miru's subtitles.
- About 3 GB of disk for the Whisper model, downloaded from Hugging Face on the first job, plus room for
  the transcripts.

## Running it

Kaku lives in the [`Server/kaku`](https://github.com/zacaronii/amatsubame/tree/main/Server/kaku) folder
of the repository.

1. Copy the example settings:

   ```sh
   cd Server/kaku
   cp env.example .env
   ```

2. Fill in `.env`. It holds keys, so keep it private (Git ignores it).

   | Setting | What to put |
   | --- | --- |
   | `AUDIOBOOKSHELF_URL` | Audiobookshelf's address as Kaku reaches it, for example `http://audiobookshelf.example.com:13378` |
   | `AUDIOBOOKSHELF_API_KEY` | An API key from Audiobookshelf's Settings ▸ API Keys |
   | `KAKU_API_TOKEN` | Any long random string, for example from `openssl rand -hex 32`. The apps send it with every request |
   | `JELLYFIN_URL`, `JELLYFIN_API_KEY` | Optional: Jellyfin's address and an API key made for Kaku in Jellyfin's Dashboard ▸ API Keys |
   | `KAKU_PORT` | The port on the host (8000 unless you change it) |
   | `TZ` | Your time zone, for example `Asia/Tokyo` |

3. Build and start it:

   ```sh
   docker compose up -d --build
   ```

   The database and transcripts are kept in `./data`, and the Whisper model in `./models`, both next to
   the compose file.

4. Check that it's up:

   ```sh
   curl http://kaku.example.com:8000/health
   ```

   This is the only address that works without the token. It shows the version, whether the model is
   loaded, GPU memory, the job counts and whether Jellyfin is set up.

:::note
Kaku stops at startup if `AUDIOBOOKSHELF_URL`, `AUDIOBOOKSHELF_API_KEY` or `KAKU_API_TOKEN` is
missing. `docker compose logs kaku` shows why.
:::

## Turning libraries on

Every library starts switched off, so an English library is never transcribed by accident. There's no
screen for this yet: you use two requests with your token.

List Audiobookshelf's libraries:

```sh
curl -H "Authorization: Bearer YOUR_TOKEN" http://kaku.example.com:8000/libraries
```

Each library has an `id`, its `name`, its `mediaType` (podcast or book) and whether it's `enabled`.
Then turn on the Japanese ones by sending their ids:

```sh
curl -X PUT -H "Authorization: Bearer YOUR_TOKEN" -H "Content-Type: application/json" \
  -d '{"enabled": ["first-library-id", "second-library-id"]}' \
  http://kaku.example.com:8000/libraries
```

The list you send replaces the old one: libraries left out are switched off. Kaku then queues their
backlog. To see what it's working on:

```sh
curl -H "Authorization: Bearer YOUR_TOKEN" http://kaku.example.com:8000/jobs
```

## Connecting the apps

Each app signs in to Kaku on its own, with Kaku's address and the token (`KAKU_API_TOKEN`):

| App | Where |
| --- | --- |
| Kiku | Settings ▸ Listening ▸ Transcripts |
| Yomu | Settings ▸ Reading ▸ Read-Along ▸ Kaku |
| Miru | Settings ▸ Watching ▸ Subtitles ▸ Kaku |

Kiku and Miru also offer it in the Extras step of their first-launch setup.

Once connected:

- **Kiku** shows which episodes have a transcript. Opening one that's still waiting moves it to the
  front of Kaku's queue. While you stream, Kaku also cuts the audio clips for your cards.
- **Miru**: open the Subtitles sheet on an episode and choose **Transcribe with Kaku**, or **Transcribe
  the Rest of the Season** for the later episodes too. The sheet shows the queue place and progress.
  Kaku uses the episode's Japanese audio track and refuses an episode without one.

## Keep it private

The compose file publishes plain HTTP. That's fine on your home network, but before you use Kaku away
from home, put it behind HTTPS (a reverse proxy) or a VPN such as Tailscale. The token is sent with every
request, and nothing else protects Kaku.

## Updating

Pull the new code, then build and start it again:

```sh
git pull
cd Server/kaku
docker compose up -d --build
```

`./data` and `./models` are kept, so transcripts and the model survive.

When an update changes how lines are split into sentences, you can split the transcripts you already
have again, from the words they store, without the GPU. Back up `data/transcripts` first, then:

```sh
docker compose exec kaku python3 -m kaku.resplit --dry-run   # see what would change
docker compose exec kaku python3 -m kaku.resplit
```

## Other settings

These aren't in the compose file; add them under `environment:` to use them:

| Setting | Default | What it does |
| --- | --- | --- |
| `KAKU_MODEL` | `large-v3` | The Whisper model |
| `KAKU_POLL_SECONDS` | `300` | How often Kaku looks for new episodes |
| `KAKU_IDLE_UNLOAD_SECONDS` | `600` | How long the model stays loaded with nothing to do |

## Known limits

- Some shows' transcripts get speaker names written into the text without punctuation. Those lines are
  only split at pauses.
- Word timings are faster-whisper's own, so a word's start can be a little off.
