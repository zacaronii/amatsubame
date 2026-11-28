"""Settings the web page can change (1.11): kept in the database over the environment's, applied
without a restart. Paths and keys stay in the environment."""
from __future__ import annotations

import os
from dataclasses import dataclass

from .pipeline import ANIME_WHISPER, ANIME_WHISPER_FOLDER, ModelNotReady, check_converted

# Models faster-whisper can download by name (into the models folder's Hugging Face cache).
DOWNLOADABLE = ('large-v3', 'large-v3-turbo')
# Hugging Face repos those names come from, as the cache names their folders.
CACHE_FOLDERS = {'models--Systran--faster-whisper-large-v3': 'large-v3',
                 'models--mobiuslabsgmbh--faster-whisper-large-v3-turbo': 'large-v3-turbo'}


@dataclass(frozen=True)
class Setting:
    key: str
    label: str
    kind: str          # 'model', 'int' or 'text'
    when: str          # when a change takes effect, as the page says it
    minimum: int = 0
    maximum: int = 0
    help: str = ''


SETTINGS = (
    Setting('model', 'Model', 'model', 'next job',
            help='New jobs and Transcribe Again only: nothing already transcribed is made again.'),
    Setting('chunk_length', 'Chunk length (seconds)', 'int', 'next job', 5, 30,
            help='Seconds of audio per chunk. anime-whisper was trained on short clips (15).'),
    Setting('prompt', 'Prompt', 'text', 'next job', 0, 300,
            help='Empty: the model’s own default (none for anime-whisper). “none”: no prompt. Anything else primes every job.'),
    Setting('new_days', 'New for (days)', 'int', 'next check', 1, 365,
            help='Episodes added this recently are new: ahead of the backlog (and the only ones in a new-only library).'),
    Setting('poll_seconds', 'Check Audiobookshelf every (seconds)', 'int', 'now', 60, 86400),
    Setting('idle_unload_seconds', 'Unload the model after idle (seconds)', 'int', 'now', 0, 86400,
            help='Gives the GPU memory back (to Jellyfin) when there’s nothing to do.'),
)
BY_KEY = {setting.key: setting for setting in SETTINGS}


def cached_models(models_dir):
    """Models already in the models folder: anime-whisper's conversion, and downloads in the cache."""
    found = []
    if models_dir and os.path.isdir(os.path.join(models_dir, ANIME_WHISPER_FOLDER)):
        found.append(ANIME_WHISPER)
    hub = os.path.join(models_dir or '', 'hub')
    if os.path.isdir(hub):
        found += [name for folder, name in CACHE_FOLDERS.items() if os.path.isdir(os.path.join(hub, folder))]
    return found


def model_choices(models_dir, current):
    """anime-whisper, the downloadable names, and the one in use; each with whether it's on disk."""
    cached = set(cached_models(models_dir))
    names = [ANIME_WHISPER, *DOWNLOADABLE]
    if current not in names:
        names.append(current)
    return [(name, name in cached) for name in names]


def check_model(name, models_dir):
    """Whether `name` can be used, in words: (ok, message)."""
    if name == ANIME_WHISPER:
        try:
            check_converted(os.path.join(models_dir or '/models', ANIME_WHISPER_FOLDER))
        except ModelNotReady as error:
            return False, str(error)
        return True, 'anime-whisper is converted and ready.'
    if name in cached_models(models_dir):
        return True, f'{name} is in the models folder.'
    if name in DOWNLOADABLE:
        return True, f'{name} isn’t downloaded yet: it downloads into the models folder (about 3 GB) on its first job.'
    return False, f'Kaku doesn’t know a model called “{name}”.'


def parse(setting, raw, models_dir, current_model):
    """The value to keep for `raw` from the page; ValueError with the reason when it doesn't fit."""
    raw = (raw or '').strip()
    if setting.kind == 'int':
        try:
            value = int(raw)
        except ValueError:
            raise ValueError(f'{setting.label}: a whole number, please.') from None
        if not setting.minimum <= value <= setting.maximum:
            raise ValueError(f'{setting.label}: between {setting.minimum} and {setting.maximum}.')
        return str(value)
    if setting.kind == 'model':
        if raw not in {name for name, _ in model_choices(models_dir, current_model)}:
            raise ValueError(f'Kaku doesn’t know a model called “{raw}”.')
        ok, message = check_model(raw, models_dir)
        if not ok:
            raise ValueError(message)
        return raw
    if len(raw) > setting.maximum:
        raise ValueError(f'{setting.label}: at most {setting.maximum} characters.')
    return raw


def value_of(setting, stored, config):
    """The setting's value: stored on the page, or else the environment's (config)."""
    if stored is not None:
        if setting.kind == 'int':
            return int(stored)
        if setting.key == 'prompt':
            from .config import Config
            return Config.prompt_setting(stored)
        return stored
    return getattr(config, setting.key)


def apply(service, key, value):
    """Puts a value to work: the poller's and worker's at once, the transcriber's from the next job."""
    if key == 'model':
        service.worker.switch_model(value)
        service.poller.model = value
    elif key == 'chunk_length':
        service.transcriber.chunk_length = value
    elif key == 'prompt':
        service.transcriber.prompt = value
    elif key == 'new_days':
        service.poller.new_days = value
    elif key == 'poll_seconds':
        service.poller.poll_seconds = value
        service.poller.wake.set()
    elif key == 'idle_unload_seconds':
        service.worker.idle_unload_seconds = value
        service.worker.wake.set()


def apply_stored(service):
    """At start: what was set on the page wins over the environment."""
    stored = service.db.settings()
    for setting in SETTINGS:
        if setting.key not in stored:
            continue
        value = value_of(setting, stored[setting.key], service.config)
        if setting.key == 'model':
            # Nothing's loaded yet: it's simply the model from the start.
            service.transcriber.name = value
            service.poller.model = value
        else:
            apply(service, setting.key, value)
