---
title: Kaku
description: Run Kaku, the Whisper transcription server that gives Kiku its transcripts, Yomu its read-along and Miru subtitles on request.
---

**Kaku** (書く, to write down) is a small server you run on a machine with an NVIDIA GPU. It keeps
the Japanese podcast and audiobook libraries in your Audiobookshelf transcribed with
[anime-whisper](https://huggingface.co/litagin/anime-whisper), a Japanese Whisper model (through
[faster-whisper](https://github.com/SYSTRAN/faster-whisper)), and hands the apps timed
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
- About 1.5 GB of disk for the converted model, plus room for the transcripts. Converting it once
  downloads about 5 GB more, which isn't kept.

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

3. Convert the model once (it runs in a throwaway container and takes a few minutes; no GPU needed):

   ```sh
   ./convert-model.sh
   ```

   anime-whisper has no ready-made build for faster-whisper, so this makes one in `./models`. See
   [The model](#the-model).

4. Build and start it:

   ```sh
   docker compose up -d --build
   ```

   The database and transcripts are kept in `./data`, and the model in `./models`, both next to the
   compose file.

5. Check that it's up:

   ```sh
   curl http://kaku.example.com:8000/health
   ```

   This is the only address that works without the token. It shows the version, whether the model is
   loaded (and `modelError` if it can't be: run `./convert-model.sh`), GPU memory, the job counts and
   whether Jellyfin is set up.

:::note
Kaku stops at startup if `AUDIOBOOKSHELF_URL`, `AUDIOBOOKSHELF_API_KEY` or `KAKU_API_TOKEN` is
missing. `docker compose logs kaku` shows why.
:::

## Turning libraries on

Every library starts switched off, so an English library is never transcribed by accident. Once an app
is connected (below), open its Kaku screen (where you entered the address) and switch on your Japanese libraries there. Kaku then
queues their backlog.

Without an app, two requests with your token do the same. List Audiobookshelf's libraries:

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

The list you send replaces the old one: libraries left out are switched off.

## Connecting the apps

Each app signs in to Kaku on its own, with Kaku's address and the token (`KAKU_API_TOKEN`),
in **Settings ▸ Kaku** in Kiku, Yomu and Miru. Kiku and Miru also offer it in the Extras step of
their first-launch setup.

Once connected, the Kaku row in Settings says in a few words what Kaku is doing ("Idle · 155
transcribed", "Transcribing · 9 waiting"), and the screen it opens shows the rest, refreshed every
few seconds:

- **Now Transcribing:** the episode or book running, with its progress.
- **Queue:** what's waiting, in order (asked for, then new this week, then the rest), with a rough
  time to the end.
- **Problems:** what failed and why, with **Try Again**.
- **Libraries:** each library's switch, and how far along it is ("120 of 131 episodes transcribed ·
  10 waiting · updated 2 hours ago"), plus the Jellyfin episodes asked for in Miru.
- **Server:** its version, the model and whether it's loaded, GPU memory, and when it last checked
  Audiobookshelf (with the error, if that failed).
- **Connection:** the address and token, with Test Connection and Remove Server.

Then:

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

`./data` and `./models` are kept, so transcripts and the model survive. Coming from Kaku 1.6 or
earlier, run `./convert-model.sh` before starting it again (or set `KAKU_MODEL=large-v3` to keep the
old model). Your transcripts are kept either way; only new ones use the new model.

When an update changes how lines are split into sentences, you can split the transcripts you already
have again, from the words they store, without the GPU. Back up `data/transcripts` first, then:

```sh
docker compose exec kaku python3 -m kaku.resplit --dry-run   # see what would change
docker compose exec kaku python3 -m kaku.resplit
```

## The model

Kaku uses **anime-whisper**, a Japanese fine-tune of Whisper made for anime and game voice acting. In
a comparison on anime episodes, audiobooks and podcasts it was more accurate than Whisper large-v3 on
all three (about a third fewer character errors on anime, half as many on audiobooks) and dropped
almost no speech on podcasts. It works without a prompt, in 15-second chunks.

What you may notice in its transcripts: some lines end without 。 (Kaku still ends them at the pause),
exclamations are written with half-width `!?`, and some spellings come from visual novels (〜, …).

Changing the model keeps the transcripts you have; new episodes and **Transcribe Again** use the new
one, and each transcript records which model made it. These settings go in `.env`:

| Setting | Default | What it does |
| --- | --- | --- |
| `KAKU_MODEL` | `anime-whisper` | The model. `large-v3` (Kaku 1.6's) downloads itself on its first job |
| `KAKU_CHUNK_LENGTH` | `15` | Seconds of audio per chunk |
| `KAKU_PROMPT` | (empty) | Empty: each model's own default (none for anime-whisper). `none`: no prompt. Any other text: primes every job with it |

## Other settings

These aren't in the compose file; add them under `environment:` to use them:

| Setting | Default | What it does |
| --- | --- | --- |
| `KAKU_POLL_SECONDS` | `300` | How often Kaku looks for new episodes |
| `KAKU_IDLE_UNLOAD_SECONDS` | `600` | How long the model stays loaded with nothing to do |

## Web page

Since Kaku 1.8 there's a page for your browser at `/ui`: what Kaku is doing now, the queue, recent
problems and your libraries, refreshing itself every few seconds. Since 1.9 you can also move a job
to the front of the queue, cancel one (or the one running, at once), try a problem again, turn
libraries on and off, have Kaku check Audiobookshelf now, and stop after the current job (until you
resume). A problem has a **Log** button (its last lines, kept 14 days), and **Kaku's log** shows what
it has written since it started. Keys and tokens are taken out of both.

Since 1.10 each library has a **Shows** (or **Books**) page where you can give each one a mode:
**High** puts it first among new episodes (and brings its backlog along), **Low** leaves it with the
backlog, **Pause** holds its jobs until you set it back to Normal, and **Skip** never transcribes it.
A library can also be set to **New only**, so Kaku skips its backlog. Asking for an episode from an
app always works, whatever the rules say.

Since 1.11 the page's **Settings** change the model, the chunk length, the prompt, how long an
episode counts as new, how often Kaku checks Audiobookshelf and when it unloads the model. A
setting changed there wins over the compose file's (also after a restart) until you choose **Use the
environment's**: changing `KAKU_MODEL` in `.env` does nothing while the page has a model saved, so
choose **Use the environment's** there first.

Since 1.12 the page has **Stats**: hours of audio transcribed per day and per library, and how fast
each model goes. Opening Kaku's bare address in a browser also takes you to the page. A new model is used from the next job on; nothing already transcribed is redone. A cancelled episode
isn't queued again by itself; asking for it from an app queues it again.

It's off unless you set `KAKU_UI_SECRET` (in the compose file) to a long random string, and it only
opens through a reverse proxy that signs you in and adds the header `X-Kaku-UI` with that string to
requests for `/ui` (with Authentik and Traefik: a forward-auth middleware and a headers middleware on
a router for the `/ui` paths). Opened any other way it answers 403, so it isn't reachable around the
sign-in. The apps' requests are unchanged, and the page never sees `KAKU_API_TOKEN`.

## Known limits

- Some shows' transcripts get speaker names written into the text without punctuation. Those lines are
  only split at pauses.
- Word timings are faster-whisper's own, so a word's start can be a little off.
