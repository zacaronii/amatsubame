# Kaku (書く)

Kaku keeps the Japanese podcast and audiobook libraries in Audiobookshelf transcribed with Whisper
large-v3 (faster-whisper) on an NVIDIA GPU, and serves timed, sentence-split transcripts to the
Amatsubame apps: Kiku's transcripts, Yomu's read-along, and (optionally, on request) Japanese
subtitles for Jellyfin episodes in Miru. Design: `docs/AUDIO_PLAN.md`; pieces, API and operations:
`docs/kaku.md`.

## Running it

You need a machine with an NVIDIA GPU (the image uses CUDA 12.8, which RTX 50-series cards need; the
host driver must support it), Docker with the NVIDIA Container Toolkit, and Audiobookshelf 2.26.0 or
later. Then, in this folder:

    cp env.example .env                 # fill it in; keep it private
    docker compose up -d --build

The database and transcripts are kept in `./data`, the Whisper model cache (about 3 GB, fetched on
the first job) in `./models`. Libraries start switched off: enable your Japanese ones with
`PUT /libraries` (see `docs/kaku.md`), then add Kaku's address and token in the apps' Settings.

The compose file publishes plain HTTP on `KAKU_PORT`. Put Kaku behind HTTPS (a reverse proxy) or a
VPN such as Tailscale before using it away from home: the bearer token is sent with every request.

## Tests

    python3 -m pytest -q tests          # no GPU needed (fastapi, httpx, pytest)

## License

MIT (`LICENSE`). faster-whisper and the Whisper weights are MIT as well; see
`THIRD_PARTY_NOTICES.md` at the repository root.
