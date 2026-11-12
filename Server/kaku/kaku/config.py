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
    model: str = 'large-v3'
    poll_seconds: int = 300
    # The model is unloaded after this long without work, giving the GPU memory back.
    idle_unload_seconds: int = 600
    # Episodes added this recently are "new" (ahead of the backlog).
    new_days: int = 7
    # Optional: Jellyfin episodes transcribed on request (Miru's subtitles when Jimaku has none).
    jellyfin_url: str = ''
    jellyfin_key: str = ''

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
            model=env.get('KAKU_MODEL', 'large-v3'),
            poll_seconds=int(env.get('KAKU_POLL_SECONDS', '300')),
            idle_unload_seconds=int(env.get('KAKU_IDLE_UNLOAD_SECONDS', '600')),
            jellyfin_url=env.get('JELLYFIN_URL', '').rstrip('/'),
            jellyfin_key=env.get('JELLYFIN_API_KEY', ''),
        )
