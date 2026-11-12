"""The one GPU worker: takes jobs in priority order, runs the pipeline, and unloads the model
when there's been nothing to do for a while (Jellyfin shares the GPU)."""
from __future__ import annotations

import datetime
import logging
import os
import shutil
import subprocess
import threading
import time

from . import PIPELINE, VERSION, model_key
from .jellyfin import PREFIX, NoJapaneseAudio, is_jellyfin
from .transcript import document, sentences, write

log = logging.getLogger('kaku.worker')
# Punctuated like the podcast prompt (so 。、 come out), without its topic.
JELLYFIN_PROMPT = 'こんにちは。元気？うん、元気だよ。そうか、よかった！'


class Gone(Exception):
    """The episode or its file is no longer in Audiobookshelf (or Jellyfin)."""


def run_quietly(command, server):
    """Runs ffmpeg; a failure says only ffmpeg's last line, since the command carries a key."""
    try:
        subprocess.run(command, check=True, capture_output=True)
    except subprocess.CalledProcessError as error:
        message = (error.stderr or b'').decode(errors='replace').strip().splitlines()[-1:] or ['ffmpeg failed']
        raise RuntimeError(f'Couldn’t read the audio from {server}: {message[0][:200]}') from None


class Worker:
    def __init__(self, db, audiobookshelf, transcriber, data_dir, idle_unload_seconds=600, jellyfin=None):
        self.db = db
        self.audiobookshelf = audiobookshelf
        self.jellyfin = jellyfin
        self.transcriber = transcriber
        self.data_dir = data_dir
        self.idle_unload_seconds = idle_unload_seconds
        self.wake = threading.Event()
        self.last_work = time.monotonic()
        self.current = None

    def transcript_folder(self, item_id):
        return os.path.join(self.data_dir, 'transcripts', item_id)

    def run_once(self):
        """Runs the next job; False when there was none."""
        job = self.db.claim()
        if job is None:
            return False
        self.current = job
        started = time.monotonic()
        try:
            path = self.process(job)
            self.db.finish(job, path, model_key(self.transcriber.name))
            log.info('transcribed %s/%s in %.0f s', job['item_id'], job['episode_id'], time.monotonic() - started)
        except Gone as error:
            self.db.fail(job, error, permanent=True)
        except Exception as error:
            log.exception('job %s/%s failed', job['item_id'], job['episode_id'])
            self.db.fail(job, error)
        finally:
            self.current = None
            self.last_work = time.monotonic()
        return True

    def episode(self, job):
        if is_jellyfin(job['item_id']):
            if self.jellyfin is None:
                raise Gone('Kaku isn’t connected to Jellyfin.')
            try:
                episode = self.jellyfin.episode(job['item_id'][len(PREFIX):])
            except NoJapaneseAudio as error:
                raise Gone(str(error)) from None
            if episode is None:
                raise Gone('The episode is no longer in Jellyfin.')
            return episode
        episode = self.audiobookshelf.episode(job['item_id'], job['episode_id'])
        if episode is None:
            raise Gone('The episode is no longer in Audiobookshelf.')
        return episode

    def process(self, job):
        episode = self.episode(job)
        # The file may have been replaced since it was queued: the transcript is of what's there now.
        job['fingerprint'] = episode.fingerprint
        work = os.path.join(self.data_dir, 'tmp', f"{job['item_id']}-{job['episode_id']}")
        os.makedirs(work, exist_ok=True)
        try:
            wav = os.path.join(work, 'audio.wav')
            self.prepare(job, episode, work, wav)
            self.db.set_progress(job, 0.05)

            def progress(seconds):
                if episode.duration > 0:
                    self.db.set_progress(job, round(0.05 + 0.95 * min(seconds / episode.duration, 1), 3))

            # Podcasts and books get the podcast prompt; Jellyfin's episodes (drama, anime) a plain one.
            prompt = JELLYFIN_PROMPT if is_jellyfin(episode.item_id) else getattr(self.transcriber, 'prompt', '')
            segments = self.transcriber.transcribe(wav, progress, prompt=prompt)
            transcript = document(
                item={'libraryItemId': episode.item_id, 'episodeId': episode.episode_id, 'libraryId': episode.library_id},
                source={'fingerprint': episode.fingerprint, 'duration': episode.duration, 'model': self.transcriber.name,
                        'modelVersion': self.transcriber.version, 'kaku': VERSION, 'pipeline': PIPELINE,
                        'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')},
                sentence_list=sentences(segments, prompt=prompt))
            name = 'video' if is_jellyfin(episode.item_id) else episode.episode_id or 'book'
            return write(self.transcript_folder(episode.item_id), name, transcript)
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def prepare(self, job, episode, work, wav):
        """The audio as one 16 kHz mono WAV. A book's files are joined in track order, each
        padded or trimmed to its length in Audiobookshelf, so times match its timeline. A Jellyfin
        episode's Japanese track is read straight from its file over HTTP."""
        if is_jellyfin(episode.item_id):
            run_quietly(['ffmpeg', '-v', 'error', '-y', '-headers', self.jellyfin.auth_header, '-i', self.jellyfin.stream_url(episode),
                         '-map', f'0:a:{episode.audio_track}', '-vn', '-ac', '1', '-ar', '16000', wav], 'Jellyfin')
            return
        if len(episode.tracks) == 1:
            source = os.path.join(work, 'source')
            self.audiobookshelf.download(episode, episode.tracks[0], source)
            self.db.set_progress(job, 0.02)
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', source, '-ac', '1', '-ar', '16000', wav], check=True)
            os.remove(source)
            return
        parts = []
        for index, track in enumerate(episode.tracks):
            source, part = os.path.join(work, f'source-{index}'), os.path.join(work, f'part-{index:04d}.wav')
            self.audiobookshelf.download(episode, track, source)
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', source, '-ac', '1', '-ar', '16000',
                            '-af', 'apad', '-t', f'{track.duration:.3f}', part], check=True)
            os.remove(source)
            parts.append(part)
            self.db.set_progress(job, round(0.04 * (index + 1) / len(episode.tracks), 3))
        listing = os.path.join(work, 'parts.txt')
        with open(listing, 'w', encoding='utf-8') as file:
            file.writelines(f"file '{part}'\n" for part in parts)
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', listing, '-c', 'copy', wav], check=True)
        for part in parts:
            os.remove(part)

    def run(self, stop):
        while not stop.is_set():
            if self.run_once():
                continue
            if self.transcriber.loaded and time.monotonic() - self.last_work > self.idle_unload_seconds:
                log.info('idle: unloading the model')
                self.transcriber.unload()
            self.wake.wait(30)
            self.wake.clear()
