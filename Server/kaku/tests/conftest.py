import json
import os
import sys
import threading
from dataclasses import replace

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from kaku.audiobookshelf import Audiobookshelf  # noqa: E402
from kaku.config import Config  # noqa: E402
from kaku.jellyfin import Jellyfin  # noqa: E402
from kaku.main import build  # noqa: E402
from kaku.transcript import Segment  # noqa: E402

FIXTURES = os.path.join(os.path.dirname(__file__), 'fixtures')
# 2026-11-05: episode-1 was added 3 days before, episode-2 about 15 days before.
NOW = 1_794_060_000


def fixture(name):
    with open(os.path.join(FIXTURES, name), encoding='utf-8') as file:
        return json.load(file)


class FakeAudiobookshelf(Audiobookshelf):
    """Answers from the recorded fixtures; `requests` lists every path asked for."""

    def __init__(self):
        super().__init__('http://abs.test', 'key')
        self.routes = {
            '/api/libraries': fixture('libraries.json'),
            '/api/libraries/lib-1/items?limit=100&page=0': fixture('library-items.json'),
            '/api/items/item-1?expanded=1': fixture('item.json'),
            # A two-file book (tracks listed out of order, as Audiobookshelf may).
            '/api/libraries/lib-2/items?limit=100&page=0': fixture('library-books.json'),
            '/api/items/book-1?expanded=1': fixture('book.json'),
        }
        self.requests = []
        self.downloads = []

    def get(self, path):
        self.requests.append(path)
        if path not in self.routes:
            import urllib.error
            raise urllib.error.HTTPError(self.url + path, 404, 'Not Found', {}, None)
        return json.loads(json.dumps(self.routes[path]))

    def download(self, episode, track, destination):
        self.downloads.append(episode.episode_id or track.ino)
        with open(destination, 'wb') as file:
            file.write(b'audio')


class FakeJellyfin(Jellyfin):
    """An anime episode with Japanese and English audio, and an English-only drama."""

    def __init__(self):
        super().__init__('http://jellyfin.test', 'jellyfin-key')
        self.items = {'jf-anime-1': fixture('jellyfin-anime.json'), 'jf-english-1': fixture('jellyfin-english.json')}
        self.requests = []

    def get(self, path):
        self.requests.append(path)
        for jellyfin_id, answer in self.items.items():
            if f'ids={jellyfin_id}&' in path:
                return json.loads(json.dumps(answer))
        return {'Items': [], 'TotalRecordCount': 0}


class Word:
    def __init__(self, text, start, end, probability=0.9):
        self.text, self.start, self.end, self.probability = text, start, end, probability


class FakeTranscriber:
    """Returns two sentences without a GPU; `gate` can hold a job running."""
    name = 'large-v3'
    version = 'fake'

    def __init__(self):
        self.loaded = False
        self.calls = []
        self.prompts = []
        self.gate = None

    def transcribe(self, wav, progress=lambda seconds: None, prompt=''):
        self.loaded = True
        self.calls.append(wav)
        self.prompts.append(prompt)
        if self.gate:
            self.gate.wait(5)
        progress(10)
        return [Segment(words=[Word('今日', 0.0, 0.4), Word('は', 0.4, 0.5), Word('晴れ', 0.5, 0.9), Word('。', 0.9, 1.0)]),
                Segment(words=[Word('明日', 1.2, 1.5), Word('も', 1.5, 1.6), Word('？', 1.6, 1.7)])]

    def unload(self):
        self.loaded = False


@pytest.fixture
def service(tmp_path, monkeypatch):
    # The worker converts with ffmpeg; tests skip it by copying the "download".
    import shutil
    import subprocess

    commands = []

    def fake_run(command, check=False, **kwargs):
        commands.append(command)
        source = command[command.index('-i') + 1]
        if source.startswith('http'):  # Jellyfin's file, read over HTTP
            with open(command[-1], 'wb') as file:
                file.write(b'audio')
        else:
            shutil.copy(source, command[-1])
        return subprocess.CompletedProcess(command, 0)
    monkeypatch.setattr('kaku.worker.subprocess.run', fake_run)
    config = Config(audiobookshelf_url='http://abs.test', audiobookshelf_key='key', api_token='secret-token',
                    data_dir=str(tmp_path))
    built = build(config, transcriber=FakeTranscriber(), audiobookshelf=FakeAudiobookshelf(), jellyfin=FakeJellyfin())
    built.commands = commands
    return built
