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
            episodes = self.audiobookshelf.episodes(library['id'])
            self.db.sync_shows(library['id'], getattr(self.audiobookshelf, 'shows', {}).get(library['id'], {}))
            # The web page's rules (1.10): a show skipped, high or low; the library new episodes only.
            rules = self.db.rules(library['id'])
            new_only = rules.get('') == 'new-only'
            for episode in episodes:
                mode = rules.get(episode.item_id)
                is_new = now - episode.added_at < self.new_days * 86400
                if mode == 'skip' or (new_only and not is_new and mode != 'high'):
                    continue
                priority = NEW if mode == 'high' else BACKLOG if mode == 'low' else NEW if is_new else BACKLOG
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
