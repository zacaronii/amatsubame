"""Settings from the environment (docker compose's env file on the server)."""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    audiobookshelf_url: str
    audiobookshelf_key: str
    api_token: str
    data_dir: str = '/data'
    # The Whisper model (docs/kaku.md ▸ Model): anime-whisper, converted once into the models
    # folder (`python3 -m kaku.convert`), or any name faster-whisper downloads (large-v3).
    model: str = 'anime-whisper'
    # Where converted models live (the Hugging Face cache is there too).
    models_dir: str = '/models'
    # Seconds of audio per batched chunk: anime-whisper was trained on short clips.
    chunk_length: int = 15
    # The text the model is primed with. None: the model's own default (anime-whisper: no prompt,
    # as its authors advise; large-v3: the punctuated prompts in pipeline.py). '' turns it off
    # (KAKU_PROMPT=none; an empty KAKU_PROMPT is the default).
    prompt: str | None = None
    poll_seconds: int = 300
    # The model is unloaded after this long without work, giving the GPU memory back.
    idle_unload_seconds: int = 600
    # Episodes added this recently are "new" (ahead of the backlog).
    new_days: int = 7
    # Optional: Jellyfin episodes transcribed on request (Miru's subtitles when Jimaku has none).
    jellyfin_url: str = ''
    jellyfin_key: str = ''

    @staticmethod
    def prompt_setting(value):
        value = value.strip()
        return None if not value else '' if value.lower() == 'none' else value

    @staticmethod
    def from_env(env=os.environ) -> 'Config':
        missing = [name for name in ('AUDIOBOOKSHELF_URL', 'AUDIOBOOKSHELF_API_KEY', 'KAKU_API_TOKEN') if not env.get(name)]
        if missing:
            raise SystemExit(f'Missing settings: {", ".join(missing)}')
        return Config(
            audiobookshelf_url=env['AUDIOBOOKSHELF_URL'].rstrip('/'),
            audiobookshelf_key=env['AUDIOBOOKSHELF_API_KEY'],
            api_token=env['KAKU_API_TOKEN'],
            data_dir=env.get('KAKU_DATA', '/data'),
            model=env.get('KAKU_MODEL') or 'anime-whisper',
            models_dir=env.get('KAKU_MODELS', '/models'),
            chunk_length=int(env.get('KAKU_CHUNK_LENGTH') or '15'),
            prompt=Config.prompt_setting(env.get('KAKU_PROMPT', '')),
            poll_seconds=int(env.get('KAKU_POLL_SECONDS', '300')),
            idle_unload_seconds=int(env.get('KAKU_IDLE_UNLOAD_SECONDS', '600')),
            jellyfin_url=env.get('JELLYFIN_URL', '').rstrip('/'),
            jellyfin_key=env.get('JELLYFIN_API_KEY', ''),
        )
