"""Runs Kaku: the poller and the GPU worker in background threads, the API in the foreground."""
from __future__ import annotations

import logging
import os
import threading
from dataclasses import dataclass

import uvicorn

from .api import create_app
from .audiobookshelf import Audiobookshelf
from .config import Config
from .db import Database
from .jellyfin import Jellyfin
from . import logs, settings
from .logs import Redactor
from .pipeline import WhisperTranscriber
from .poller import Poller
from .worker import Worker


@dataclass
class Service:
    config: Config
    db: Database
    audiobookshelf: Audiobookshelf
    transcriber: object
    worker: Worker
    poller: Poller
    jellyfin: Jellyfin | None = None


def secrets(config):
    """What the logs the web page shows must never contain."""
    return (config.api_token, config.audiobookshelf_key, config.jellyfin_key, config.ui_secret)


def build(config, transcriber=None, audiobookshelf=None, jellyfin=None):
    os.makedirs(config.data_dir, exist_ok=True)
    db = Database(os.path.join(config.data_dir, 'kaku.db'))
    audiobookshelf = audiobookshelf or Audiobookshelf(config.audiobookshelf_url, config.audiobookshelf_key)
    transcriber = transcriber or WhisperTranscriber(config.model, config.models_dir, config.chunk_length, config.prompt)
    if jellyfin is None and config.jellyfin_url and config.jellyfin_key:
        jellyfin = Jellyfin(config.jellyfin_url, config.jellyfin_key)
    worker = Worker(db, audiobookshelf, transcriber, config.data_dir, config.idle_unload_seconds, jellyfin)
    worker.redact = Redactor(secrets(config))
    poller = Poller(db, audiobookshelf, config.model, config.poll_seconds, config.new_days, on_queued=worker.wake.set)
    service = Service(config, db, audiobookshelf, transcriber, worker, poller, jellyfin)
    # What was set on the web page (1.11) wins over the environment.
    settings.apply_stored(service)
    # Transcripts from before 1.12 count in the stats too (once).
    db.backfill_history()
    return service


def main():
    logging.basicConfig(level=logging.INFO, format=logs.FORMAT)
    config = Config.from_env()
    # The last lines, for the web page's log tail (keys taken out).
    logs.install(secrets(config))
    service = build(config)
    stop = threading.Event()
    threading.Thread(target=service.poller.run, args=(stop,), daemon=True, name='poller').start()
    threading.Thread(target=service.worker.run, args=(stop,), daemon=True, name='worker').start()
    uvicorn.run(create_app(service), host='0.0.0.0', port=8000, log_level='warning')
    stop.set()


if __name__ == '__main__':
    main()
