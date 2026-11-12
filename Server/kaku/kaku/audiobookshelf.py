"""A GET-only Audiobookshelf client (verified against 2.36.1, 2026-11-05):
- `GET /api/libraries` → `{libraries: [{id, name, mediaType: "podcast" | "book"}]}`
- `GET /api/libraries/{id}/items?limit=&page=` → `{results: [{id, updatedAt, mediaType}], total}`
- `GET /api/items/{id}?expanded=1` → a podcast's `media.episodes[]` with `id`, `title`,
  `addedAt` (ms), `audioFile: {ino, duration, metadata: {size}}`; a book's (`mediaType: "book"`)
  `media.tracks[]` with `index`, `ino`, `startOffset`, `duration` on one timeline, and
  `media.audioFiles[]` with each file's `metadata.size`
- `GET /api/items/{id}/file/{ino}/download` → the audio file; `/api/items/{id}/file/{ino}` streams
  it with range requests (clips)
Kaku never writes to Audiobookshelf."""
from __future__ import annotations

import json
import shutil
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass


@dataclass(frozen=True)
class Track:
    """One audio file on the item's timeline (a podcast episode has one; a book may have many)."""
    ino: str
    start: float  # seconds into the item
    duration: float
    size: int


@dataclass(frozen=True)
class Episode:
    """A podcast episode, or a whole book (`episode_id` empty): what gets one transcript."""
    item_id: str
    episode_id: str
    library_id: str
    title: str
    added_at: float  # seconds since 1970
    tracks: tuple

    @property
    def is_book(self):
        return self.episode_id == ''

    @property
    def duration(self):
        return sum(track.duration for track in self.tracks)

    @property
    def fingerprint(self):
        """Changes when the audio does (a replaced or re-downloaded file). A podcast keeps the
        one-file form from before books, so its transcripts aren't redone."""
        if not self.is_book:
            track = self.tracks[0]
            return f'{track.ino}:{track.size}:{track.duration:.1f}'
        return '+'.join(f'{track.ino}:{track.size}:{track.duration:.1f}' for track in self.tracks)

    def track_at(self, seconds):
        """The track playing at `seconds` on the item's timeline, and the time within it."""
        for track in self.tracks:
            if seconds < track.start + track.duration:
                return track, max(seconds - track.start, 0)
        last = self.tracks[-1]
        return last, last.duration


class Audiobookshelf:
    def __init__(self, url, key, timeout=60):
        self.url = url.rstrip('/')
        self.key = key
        self.timeout = timeout
        # Item id → (updatedAt, episodes), so a poll only refetches podcasts that changed.
        self._items = {}

    def _open(self, path, timeout=None):
        request = urllib.request.Request(self.url + path, headers={'Authorization': f'Bearer {self.key}'})
        return urllib.request.urlopen(request, timeout=timeout or self.timeout)

    def get(self, path):
        with self._open(path) as response:
            return json.load(response)

    def libraries(self):
        return [{'id': l['id'], 'name': l['name'], 'mediaType': l['mediaType']} for l in self.get('/api/libraries')['libraries']]

    def episodes(self, library_id):
        """Every episode with an audio file in a podcast library, or every book with audio in a
        book library."""
        found, page, seen = [], 0, set()
        while True:
            listing = self.get(f'/api/libraries/{urllib.parse.quote(library_id)}/items?limit=100&page={page}')
            results = listing.get('results', [])
            for item in results:
                seen.add(item['id'])
                cached = self._items.get(item['id'])
                if cached is None or cached[0] != item.get('updatedAt'):
                    cached = (item.get('updatedAt'), self._item_episodes(item['id'], library_id))
                    self._items[item['id']] = cached
                found.extend(cached[1])
            page += 1
            if not results or page * 100 >= listing.get('total', 0):
                break
        for gone in set(self._items) - seen:
            if all(e.library_id == library_id for e in self._items[gone][1]):
                del self._items[gone]
        return found

    def _item_episodes(self, item_id, library_id):
        item = self.get(f'/api/items/{urllib.parse.quote(item_id)}?expanded=1')
        library_id = library_id or item.get('libraryId', '')
        if item.get('mediaType') == 'book':
            return self._book(item, item_id, library_id)
        episodes = []
        for episode in item.get('media', {}).get('episodes') or []:
            audio = episode.get('audioFile')
            if not audio or not audio.get('ino'):
                continue
            episodes.append(Episode(
                item_id=item_id, episode_id=episode['id'], library_id=library_id, title=episode.get('title') or '',
                added_at=(episode.get('addedAt') or 0) / 1000,
                tracks=(Track(ino=str(audio['ino']), start=0, duration=float(audio.get('duration') or 0),
                              size=int((audio.get('metadata') or {}).get('size') or 0)),)))
        return episodes

    @staticmethod
    def _book(item, item_id, library_id):
        media = item.get('media', {})
        sizes = {str(file.get('ino')): int((file.get('metadata') or {}).get('size') or 0) for file in media.get('audioFiles') or []}
        tracks = tuple(Track(ino=str(track['ino']), start=float(track.get('startOffset') or 0),
                             duration=float(track.get('duration') or 0), size=sizes.get(str(track['ino']), 0))
                       for track in sorted(media.get('tracks') or [], key=lambda track: track.get('index') or 0)
                       if track.get('ino'))
        if not tracks:
            return []
        return [Episode(item_id=item_id, episode_id='', library_id=library_id,
                        title=(media.get('metadata') or {}).get('title') or '', added_at=(item.get('addedAt') or 0) / 1000,
                        tracks=tracks)]

    def episode(self, item_id, episode_id):
        """One episode, or None when the item or episode doesn't exist."""
        try:
            episodes = self._item_episodes(item_id, '')
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            raise
        return next((e for e in episodes if e.episode_id == episode_id), None)

    def download(self, episode, track, destination):
        path = f'/api/items/{urllib.parse.quote(episode.item_id)}/file/{urllib.parse.quote(track.ino)}/download'
        with self._open(path, timeout=600) as response, open(destination, 'wb') as file:
            shutil.copyfileobj(response, file, 1 << 20)

    def stream_url(self, episode, track):
        """The file's URL for ffmpeg, which reads just the part it needs (range requests); send
        `auth_header` with it."""
        return f'{self.url}/api/items/{urllib.parse.quote(episode.item_id)}/file/{urllib.parse.quote(track.ino)}'

    @property
    def auth_header(self):
        return f'Authorization: Bearer {self.key}\r\n'
