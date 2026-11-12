"""Finds work: every few minutes, every episode (and book) in the enabled libraries that has no
transcript of its current audio by the current model is queued."""
from __future__ import annotations

import logging
import threading
import time

from . import model_key
from .db import BACKLOG, NEW

log = logging.getLogger('kaku.poller')


class Poller:
    def __init__(self, db, audiobookshelf, model, poll_seconds=300, new_days=7, on_queued=lambda: None):
        self.db = db
        self.audiobookshelf = audiobookshelf
        self.model = model
        self.poll_seconds = poll_seconds
        self.new_days = new_days
        self.on_queued = on_queued
        # Set to poll straight away (a library was switched on).
        self.wake = threading.Event()

    def poll_once(self, now=None):
        """Returns how many episodes were queued."""
        now = now or time.time()
        libraries = self.audiobookshelf.libraries()
        self.db.sync_libraries(libraries)
        enabled = set(self.db.enabled_libraries())
        queued = 0
        for library in libraries:
            if library['id'] not in enabled:
                continue
            for episode in self.audiobookshelf.episodes(library['id']):
                priority = NEW if now - episode.added_at < self.new_days * 86400 else BACKLOG
                queued += self.db.offer(episode, priority, model_key(self.model), now=now)
        self.db.set_meta('last_poll', now)
        self.db.set_meta('last_poll_error', '')
        if queued:
            log.info('queued %d episode(s)', queued)
            self.on_queued()
        return queued

    def run(self, stop):
        while not stop.is_set():
            try:
                self.poll_once()
            except Exception as error:  # A server that's down is tried again next time.
                log.warning('poll failed: %s', error)
                self.db.set_meta('last_poll_error', str(error)[:300])
            self.wake.wait(self.poll_seconds)
            self.wake.clear()
