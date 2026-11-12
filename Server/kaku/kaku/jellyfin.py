"""Jellyfin, read-only: an episode's details and its Japanese audio, for subtitles Jimaku lacks.
Jobs are only made on request (Miru's Transcribe with Kaku); nothing is polled. In Kaku's
queue and storage a Jellyfin item is "jf:<id>" with no episode, beside Audiobookshelf's ids."""
from __future__ import annotations

import datetime
import json
import urllib.parse
import urllib.request
from dataclasses import dataclass

PREFIX = 'jf:'
LIBRARY = 'jellyfin'
JAPANESE = {'jpn', 'ja', 'jp'}


def kaku_id(jellyfin_id):
    return PREFIX + jellyfin_id


def is_jellyfin(item_id):
    return item_id.startswith(PREFIX)


class NoJapaneseAudio(Exception):
    """The episode's audio is all in other languages."""


@dataclass(frozen=True)
class JellyfinEpisode:
    jellyfin_id: str
    media_source_id: str
    title: str
    added_at: float
    duration: float
    fingerprint: str
    # The Japanese track among the file's audio tracks (ffmpeg's `0:a:<n>`).
    audio_track: int

    @property
    def item_id(self):
        return kaku_id(self.jellyfin_id)

    @property
    def episode_id(self):
        return ''

    @property
    def library_id(self):
        return LIBRARY


class Jellyfin:
    def __init__(self, url, api_key, timeout=30):
        self.url = url.rstrip('/')
        self.api_key = api_key
        self.timeout = timeout

    @property
    def auth_header(self):
        """For ffmpeg's `-headers` (never logged: it carries the key)."""
        return f'Authorization: MediaBrowser Token="{self.api_key}"\r\n'

    def get(self, path):
        request = urllib.request.Request(self.url + path, headers={'Authorization': f'MediaBrowser Token="{self.api_key}"'})
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            return json.load(response)

    def episode(self, jellyfin_id):
        """The episode, or None if Jellyfin doesn't have it. `/Items/{id}` needs a user with an
        API key (Jellyfin 12.3); `/Items?ids=` doesn't."""
        query = urllib.parse.urlencode({'ids': jellyfin_id, 'fields': 'MediaSources,DateCreated'})
        items = self.get(f'/Items?{query}').get('Items') or []
        return episode_from(items[0]) if items else None

    def stream_url(self, episode):
        query = urllib.parse.urlencode({'static': 'true', 'mediaSourceId': episode.media_source_id})
        return f'{self.url}/Videos/{episode.jellyfin_id}/stream?{query}'


def episode_from(item):
    """Raises NoJapaneseAudio when every audio track is tagged with another language; an
    untagged track counts (it's often the original)."""
    sources = item.get('MediaSources') or []
    if not sources:
        return None
    source = sources[0]
    audio = [stream for stream in source.get('MediaStreams') or [] if stream.get('Type') == 'Audio' and not stream.get('IsExternal')]
    if not audio:
        return None
    track = next((index for index, stream in enumerate(audio) if (stream.get('Language') or '').lower() in JAPANESE), None)
    if track is None:
        track = next((index for index, stream in enumerate(audio) if (stream.get('Language') or 'und').lower() == 'und'), None)
    if track is None:
        raise NoJapaneseAudio('This episode has no Japanese audio track.')
    ticks = source.get('RunTimeTicks') or item.get('RunTimeTicks') or 0
    title = item.get('Name') or ''
    if item.get('SeriesName'):
        number = f"S{item.get('ParentIndexNumber') or 0}E{item.get('IndexNumber') or 0}"
        title = f"{item['SeriesName']} {number} {title}".strip()
    created = item.get('DateCreated')
    added = datetime.datetime.fromisoformat(created[:19]).replace(tzinfo=datetime.timezone.utc).timestamp() if created else 0
    return JellyfinEpisode(
        jellyfin_id=item['Id'], media_source_id=source['Id'], title=title, added_at=added, duration=ticks / 10_000_000,
        fingerprint=f"{source['Id']}:{source.get('Size') or 0}:{ticks}:a{track}", audio_track=track)
