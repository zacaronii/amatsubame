"""Kaku's HTTP API (docs/kaku.md). Everything but /health needs `Authorization: Bearer <token>`."""
from __future__ import annotations

import hmac
import json
import os
import subprocess
import tempfile
import time

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from pydantic import BaseModel

from . import VERSION, model_key
from .db import NOW, PRIORITY_NAMES
from .jellyfin import NoJapaneseAudio, kaku_id
from .transcript import srt


class JobRequest(BaseModel):
    itemId: str
    # Empty (or left out) for a book.
    episodeId: str = ''


class LibrariesRequest(BaseModel):
    enabled: list[str]


class StatusRequest(BaseModel):
    episodes: list[JobRequest]


class JellyfinRequest(BaseModel):
    # Jellyfin item ids; jobs run in this order.
    itemIds: list[str]


# One status request covers a show page; more than this is a mistake.
MAX_STATUS = 2000
# One request queues a season at most.
MAX_JELLYFIN_JOBS = 100
# A clip is a line or a mark's few seconds, never a whole episode.
MAX_CLIP_SECONDS = 60


def key(item_id, episode_id):
    """The apps' key: "<item>/<episode>", or the item alone for a book."""
    return f'{item_id}/{episode_id}' if episode_id else item_id


def job_view(job, position=None):
    if job is None:
        return None
    return {
        'itemId': job['item_id'], 'episodeId': job['episode_id'], 'libraryId': job['library_id'], 'title': job['title'],
        'state': job['state'], 'priority': PRIORITY_NAMES.get(job['priority'], 'backlog'),
        'progress': job['progress'], 'error': job['error'], 'attempts': job['attempts'],
        **({'position': position} if position is not None else {}),
    }


def create_app(service):
    """`service` holds config, db, audiobookshelf, jellyfin (or None), worker, poller and
    transcriber (see main.py)."""
    app = FastAPI(title='Kaku', version=VERSION, docs_url=None, redoc_url=None, openapi_url=None)
    db = service.db

    def authorized(request: Request):
        header = request.headers.get('authorization', '')
        token = header[7:] if header.lower().startswith('bearer ') else ''
        if not token or not hmac.compare_digest(token.encode(), service.config.api_token.encode()):
            raise HTTPException(401, 'A valid bearer token is required.', headers={'WWW-Authenticate': 'Bearer'})

    def waiting(item_id, episode_id):
        job = db.job(item_id, episode_id)
        return job_view(job, db.position(item_id, episode_id))

    @app.get('/health')
    def health():
        from .pipeline import gpu_memory
        memory = gpu_memory()
        last_poll = db.meta('last_poll')
        return {
            'version': VERSION, 'model': service.transcriber.name, 'modelLoaded': service.transcriber.loaded,
            'gpu': {'usedMB': memory[0], 'totalMB': memory[1]} if memory else None,
            'jobs': db.counts(), 'lastPoll': float(last_poll) if last_poll else None,
            'lastPollError': db.meta('last_poll_error') or None,
            'jellyfin': service.jellyfin is not None,
        }

    @app.get('/transcripts/{item_id}', dependencies=[Depends(authorized)])
    def book_transcript(item_id: str, format: str = 'json'):
        return transcript(item_id, '', format)

    @app.get('/transcripts/{item_id}/{episode_id}', dependencies=[Depends(authorized)])
    def transcript(item_id: str, episode_id: str, format: str = 'json'):
        saved = db.transcript(item_id, episode_id)
        job = db.job(item_id, episode_id)
        # A newer job (changed audio, another model) is waiting, but the old transcript still serves.
        if saved:
            path = saved['path'] if format == 'json' else saved['path'][:-len('json')] + 'vtt'
            return FileResponse(path, media_type='application/json' if format == 'json' else 'text/vtt; charset=utf-8')
        if job:
            return JSONResponse(waiting(item_id, episode_id), status_code=202)
        raise HTTPException(404, f'Kaku has no transcript or job for this {"book" if not episode_id else "episode"}. POST /jobs to ask for one.')

    @app.post('/transcripts/status', dependencies=[Depends(authorized)])
    def statuses(request: StatusRequest):
        """Each episode's state for badges: done (a transcript is ready), queued, running,
        failed, or missing. A transcript being redone still counts as done."""
        if len(request.episodes) > MAX_STATUS:
            raise HTTPException(400, f'Ask for at most {MAX_STATUS} episodes at a time.')
        answer = {}
        for episode in request.episodes:
            name = key(episode.itemId, episode.episodeId)
            if db.transcript(episode.itemId, episode.episodeId):
                answer[name] = 'done'
            else:
                job = db.job(episode.itemId, episode.episodeId)
                answer[name] = job['state'] if job and job['state'] in ('queued', 'running', 'failed') else 'missing'
        return {'statuses': answer}

    @app.post('/jobs', dependencies=[Depends(authorized)])
    def ask(request: JobRequest):
        saved = db.transcript(request.itemId, request.episodeId)
        episode = service.audiobookshelf.episode(request.itemId, request.episodeId)
        if episode is None:
            raise HTTPException(404, f'Audiobookshelf has no such {"book" if not request.episodeId else "episode"}.')
        if saved and saved['fingerprint'] == episode.fingerprint and saved['model'] == model_key(service.transcriber.name):
            return JSONResponse({'itemId': request.itemId, 'episodeId': request.episodeId, 'state': 'done'})
        db.offer(episode, NOW, model_key(service.transcriber.name))
        service.worker.wake.set()
        return JSONResponse(waiting(request.itemId, request.episodeId), status_code=202)

    @app.get('/jobs', dependencies=[Depends(authorized)])
    def jobs(limit: int = 50):
        queue = db.queue()
        running = next((job for job in queue if job['state'] == 'running'), None)
        return {
            'running': job_view(running),
            'queued': [job_view(job, index) for index, job in enumerate(queue) if job['state'] == 'queued'][:limit],
            'counts': db.counts(),
            'failed': [job_view(job) for job in db.failed()],
        }

    @app.get('/libraries', dependencies=[Depends(authorized)])
    def libraries():
        if not db.libraries():
            db.sync_libraries(service.audiobookshelf.libraries())
        return {'libraries': [{'id': l['id'], 'name': l['name'], 'mediaType': l['media_type'], 'enabled': l['enabled']}
                              for l in db.libraries()]}

    @app.put('/libraries', dependencies=[Depends(authorized)])
    def set_libraries(request: LibrariesRequest):
        known = {l['id']: l for l in db.libraries()} or None
        if known is None:
            db.sync_libraries(service.audiobookshelf.libraries())
            known = {l['id']: l for l in db.libraries()}
        unknown = [library_id for library_id in request.enabled if library_id not in known]
        if unknown:
            raise HTTPException(400, f'No such library: {", ".join(unknown)}')
        for library_id in known:
            db.set_enabled(library_id, library_id in request.enabled)
        service.poller.wake.set()
        return libraries()

    @app.get('/clips/{item_id}', dependencies=[Depends(authorized)])
    def book_clip(item_id: str, start: float, end: float):
        return clip(item_id, '', start, end)

    @app.get('/clips/{item_id}/{episode_id}', dependencies=[Depends(authorized)])
    def clip(item_id: str, episode_id: str, start: float, end: float):
        """A part of the audio as AAC in .m4a, for card audio when the app streams: ffmpeg reads
        just that part of the file from Audiobookshelf. A clip stays inside one file."""
        if not 0 <= start < end or end - start > MAX_CLIP_SECONDS:
            raise HTTPException(400, f'Ask for 0 < length ≤ {MAX_CLIP_SECONDS} s, from start ≥ 0.')
        episode = service.audiobookshelf.episode(item_id, episode_id)
        if episode is None:
            raise HTTPException(404, 'Audiobookshelf has no such episode or book.')
        if start >= episode.duration:
            raise HTTPException(400, 'The clip starts after the end of the audio.')
        track, offset = episode.track_at(start)
        length = min(end - start, track.duration - offset)
        handle, output = tempfile.mkstemp(suffix='.m4a')
        os.close(handle)
        try:
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-headers', service.audiobookshelf.auth_header,
                            '-ss', f'{offset:.3f}', '-t', f'{length:.3f}', '-i', service.audiobookshelf.stream_url(episode, track),
                            '-vn', '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart', output],
                           check=True, timeout=60, capture_output=True)
            with open(output, 'rb') as file:
                data = file.read()
        except subprocess.TimeoutExpired:
            raise HTTPException(504, 'Cutting the clip from Audiobookshelf took too long.') from None
        except subprocess.CalledProcessError as error:
            # Only ffmpeg's message: the command line carries the Audiobookshelf key.
            message = (error.stderr or b'').decode(errors='replace').strip().splitlines()[-1:] or ['ffmpeg failed']
            raise HTTPException(502, f'Couldn’t cut the clip from Audiobookshelf: {message[0][:200]}') from None
        finally:
            os.remove(output)
        return Response(data, media_type='audio/mp4')

    # Jellyfin: subtitles for episodes Jimaku lacks, on request only.

    def jellyfin():
        if service.jellyfin is None:
            raise HTTPException(503, 'Kaku isn’t connected to Jellyfin (JELLYFIN_URL and JELLYFIN_API_KEY).')
        return service.jellyfin

    def jellyfin_state(jellyfin_id):
        item_id = kaku_id(jellyfin_id)
        if db.transcript(item_id, ''):
            return {'itemId': jellyfin_id, 'state': 'done'}
        job = db.job(item_id, '')
        if job is None:
            return {'itemId': jellyfin_id, 'state': 'missing'}
        position = db.position(item_id, '')
        return {'itemId': jellyfin_id, 'state': job['state'], 'progress': job['progress'], 'error': job['error'],
                **({'position': position} if position is not None else {})}

    @app.post('/jellyfin/jobs', dependencies=[Depends(authorized)])
    def ask_jellyfin(request: JellyfinRequest):
        """Queues episodes at the front, in the order given; each answer is done, queued,
        running, or unavailable (not in Jellyfin, or no Japanese audio)."""
        if not 0 < len(request.itemIds) <= MAX_JELLYFIN_JOBS:
            raise HTTPException(400, f'Ask for 1 to {MAX_JELLYFIN_JOBS} episodes.')
        server = jellyfin()
        answers, now, model = [], time.time(), model_key(service.transcriber.name)
        for index, jellyfin_id in enumerate(request.itemIds):
            try:
                episode = server.episode(jellyfin_id)
            except NoJapaneseAudio as error:
                answers.append({'itemId': jellyfin_id, 'state': 'unavailable', 'error': str(error)})
                continue
            if episode is None:
                answers.append({'itemId': jellyfin_id, 'state': 'unavailable', 'error': 'Jellyfin has no such episode.'})
                continue
            saved = db.transcript(episode.item_id, '')
            if not (saved and saved['fingerprint'] == episode.fingerprint and saved['model'] == model):
                db.offer(episode, NOW, model, now=now + index / 1000)
            answers.append(jellyfin_state(jellyfin_id))
        service.worker.wake.set()
        return {'jobs': answers}

    @app.post('/jellyfin/transcripts/status', dependencies=[Depends(authorized)])
    def jellyfin_statuses(request: JellyfinRequest):
        if len(request.itemIds) > MAX_STATUS:
            raise HTTPException(400, f'Ask for at most {MAX_STATUS} episodes at a time.')
        return {'statuses': {jellyfin_id: jellyfin_state(jellyfin_id)['state'] for jellyfin_id in request.itemIds}}

    @app.get('/jellyfin/transcripts/{jellyfin_id}', dependencies=[Depends(authorized)])
    def jellyfin_transcript(jellyfin_id: str, format: str = 'json'):
        """The transcript as JSON, WebVTT or SubRip; 202 with the job while it's waiting."""
        if format not in ('json', 'vtt', 'srt'):
            raise HTTPException(400, 'format is json, vtt or srt.')
        saved = db.transcript(kaku_id(jellyfin_id), '')
        if saved:
            if format == 'srt':
                with open(saved['path'], encoding='utf-8') as file:
                    return Response(srt(json.load(file)), media_type='application/x-subrip; charset=utf-8')
            path = saved['path'] if format == 'json' else saved['path'][:-len('json')] + 'vtt'
            return FileResponse(path, media_type='application/json' if format == 'json' else 'text/vtt; charset=utf-8')
        if db.job(kaku_id(jellyfin_id), ''):
            return JSONResponse(jellyfin_state(jellyfin_id), status_code=202)
        raise HTTPException(404, 'Kaku has no transcript or job for this episode. POST /jellyfin/jobs to ask for one.')

    return app
