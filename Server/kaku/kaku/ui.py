"""Kaku's web page (docs/kaku.md ▸ Web page): status, queue, failures and libraries, with the queue's
actions (1.9). It's served only behind a proxy that logs you in and adds `X-Kaku-UI: <KAKU_UI_SECRET>`;
the page never sees the API token, and its own routes (/ui, /ui/sections, /ui/api/action,
/ui/static/…) call the database directly instead of the bearer API. Changes need the page's CSRF
token and its own Origin, and each is recorded with who made it."""
from __future__ import annotations

import hashlib
import hmac
import os
import time
from html import escape

from urllib.parse import urlsplit

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import Response
from pydantic import BaseModel

from . import VERSION
from .db import PRIORITY_NAMES

STATIC = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ui_static')
# Who logged in, as the proxy (Authentik) says; kept with each change once the page makes any.
USER_HEADER = 'x-authentik-username'
# No inline script or style anywhere, so the page can forbid them.
SECURITY_HEADERS = {
    'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; "
                               "img-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    'Cache-Control': 'no-store',
}


def csrf_token(secret, user, day=None):
    """The page's token for changes (from M2): the user and the day, signed with the UI secret, so
    a page left open overnight still works the next day (`csrf_valid` takes yesterday's too)."""
    day = int(time.time() // 86400) if day is None else day
    return hmac.new(secret.encode(), f'{user}:{day}'.encode(), hashlib.sha256).hexdigest()


def csrf_valid(secret, user, token, now=None):
    if not token:
        return False
    today = int((time.time() if now is None else now) // 86400)
    return any(hmac.compare_digest(token, csrf_token(secret, user, day)) for day in (today, today - 1))


def ago(timestamp, now=None):
    """"5 min ago", for times in the past (Unix seconds)."""
    if not timestamp:
        return 'never'
    seconds = max(0, (time.time() if now is None else now) - timestamp)
    for size, unit in ((86400, 'd'), (3600, 'h'), (60, 'min')):
        if seconds >= size:
            return f'{int(seconds // size)} {unit} ago'
    return 'just now'


def duration(seconds):
    if seconds is None:
        return '—'
    minutes = int(seconds // 60)
    return f'{minutes // 60} h {minutes % 60} min' if minutes >= 60 else f'{minutes} min'


class Action(BaseModel):
    """A button on the page: what to do, and to which job or library."""
    action: str
    itemId: str = ''
    episodeId: str = ''
    libraryId: str = ''


def button(label, action, confirm=None, **target):
    """A form-less button the page's script sends (`data-…` attributes, no inline handlers)."""
    data = ''.join(f' data-{name}="{escape(value)}"' for name, value in target.items())
    ask = f' data-confirm="{escape(confirm)}"' if confirm else ''
    return f'<button type="button" data-action="{action}"{data}{ask}>{escape(label)}</button>'


def add_ui(app: FastAPI, service):
    config = service.config
    db = service.db

    def gate(request: Request):
        """Only through the proxy: 404 when the page is off (no secret), 403 without the proxy's header."""
        if not config.ui_secret:
            raise HTTPException(404)
        sent = request.headers.get('x-kaku-ui', '')
        if not hmac.compare_digest(sent.encode(), config.ui_secret.encode()):
            raise HTTPException(403, 'Open this page through the Kaku address that signs you in.')
        return request.headers.get(USER_HEADER, '') or 'unknown'

    def page(body, status=200, media_type='text/html; charset=utf-8'):
        return Response(body, status_code=status, media_type=media_type, headers=SECURITY_HEADERS)

    # Sections

    def status_section(now):
        from .pipeline import gpu_memory
        worker = service.worker
        memory = gpu_memory()
        last_poll = db.meta('last_poll')
        poll_error = db.meta('last_poll_error')
        transcriber = service.transcriber
        rows = [
            ('Kaku', VERSION),
            ('Model', f'{transcriber.name} · {"loaded" if transcriber.loaded else "not loaded"}'),
            ('GPU memory', f'{memory[0] / 1024:.1f} of {memory[1] / 1024:.1f} GB in use' if memory else 'not available'),
            ('Audiobookshelf checked', ago(float(last_poll), now) if last_poll else 'never'),
            ('Jellyfin', 'connected' if service.jellyfin is not None else 'not set up'),
        ]
        html = ''.join(f'<dt>{escape(name)}</dt><dd>{escape(value)}</dd>' for name, value in rows)
        problems = ''
        if worker.model_error:
            problems += f'<p class="problem">Model: {escape(worker.model_error)}</p>'
        if poll_error:
            problems += f'<p class="problem">Last Audiobookshelf check: {escape(poll_error)}</p>'
        if db.paused:
            problems += '<p class="problem">Stopped: no new job starts until you resume.</p>'
        controls = button('Check Audiobookshelf now', 'poll') + (
            button('Resume the queue', 'resume') if db.paused else
            button('Stop after this one', 'pause', confirm='Let the current job finish, then start nothing new?'))
        changes = db.changes(5)
        recent = ''.join(f'<li><span class="title">{escape(change["action"])} · {escape(change["detail"])}</span>'
                         f'<span class="detail">{escape(change["user"])} · {escape(ago(change["at"], now))}</span></li>'
                         for change in changes)
        recent = f'<h3>Recent changes</h3><ul class="jobs">{recent}</ul>' if changes else ''
        return (f'<section id="status"><h2>Status</h2><dl>{html}</dl>{problems}'
                f'<p class="controls">{controls}</p>{recent}</section>')

    def job_row(job, now, position=None):
        progress = f' · {round(job["progress"] * 100)}%' if job['state'] == 'running' else ''
        target = {'item': job['item_id'], 'episode': job['episode_id']}
        actions = ''
        if job['state'] == 'queued':
            actions = ((button('Next', 'next', **target) if position else '')
                       + button('Cancel', 'cancel', confirm=f'Take “{job["title"]}” out of the queue?', **target))
        return (f'<li><span class="title">{escape(job["title"])}</span>'
                f'<span class="detail">{escape(PRIORITY_NAMES.get(job["priority"], "backlog"))}'
                f'{"" if position is None else f" · #{position + 1}"}{progress}</span>'
                f'<span class="actions">{actions}</span></li>')

    def queue_section(now):
        queue = db.queue()
        running = next((job for job in queue if job['state'] == 'running'), None)
        queued = [job for job in queue if job['state'] == 'queued']
        average = db.average_seconds()
        left = len(queued) + (1 - running['progress'] if running else 0)
        estimate = f', about {duration(average * left)}' if average is not None and left else ''
        now_html = f'<ul class="jobs">{job_row(running, now)}</ul>' if running else '<p class="quiet">Nothing is being transcribed.</p>'
        shown = queued[:50]
        rest = f'<p class="quiet">and {len(queued) - len(shown)} more</p>' if len(queued) > len(shown) else ''
        queued_html = (f'<ol class="jobs">{"".join(job_row(job, now, index) for index, job in enumerate(shown))}</ol>{rest}'
                       if queued else '<p class="quiet">The queue is empty.</p>')
        return (f'<section id="queue"><h2>Now transcribing</h2>{now_html}'
                f'<h2>Queue ({len(queued)}{escape(estimate)})</h2>{queued_html}</section>')

    def failures_section(now):
        failed = db.failed()
        if not failed:
            return '<section id="failures"><h2>Problems</h2><p class="quiet">None.</p></section>'
        rows = ''.join(
            f'<li><span class="title">{escape(job["title"])}</span>'
            f'<span class="detail">{escape(ago(job["finished_at"], now))} · {job["attempts"]} '
            f'{"try" if job["attempts"] == 1 else "tries"}</span>'
            f'<span class="actions">{button("Try again", "retry", item=job["item_id"], episode=job["episode_id"])}</span>'
            f'<span class="error">{escape(job["error"] or "")}</span></li>' for job in failed)
        return f'<section id="failures"><h2>Problems</h2><ul class="jobs">{rows}</ul></section>'

    def libraries_section(now):
        if not db.libraries():
            try:
                db.sync_libraries(service.audiobookshelf.libraries())
            except Exception as error:
                return (f'<section id="libraries"><h2>Libraries</h2>'
                        f'<p class="problem">Couldn’t read Audiobookshelf’s libraries: {escape(str(error))}</p></section>')
        stats = db.library_counts()

        def row(name, library_id, enabled, kind, switchable=True):
            entry = stats.get(library_id, {'counts': {}, 'last': None})
            counts = entry['counts']
            done, waiting = counts.get('done', 0), counts.get('queued', 0) + counts.get('running', 0)
            state = 'on' if enabled else 'off'
            switch = ''
            if switchable:
                switch = (button('Turn off', 'library-off', library=library_id,
                                 confirm=f'Turn off “{name}”? Its waiting and failed jobs are removed; transcripts stay.')
                          if enabled else button('Turn on', 'library-on', library=library_id))
            return (f'<li><span class="title">{escape(name)}</span><span class="detail">{escape(kind)} · {state} · '
                    f'{done} transcribed · {waiting} waiting · {counts.get("failed", 0)} failed · '
                    f'last {escape(ago(entry["last"], now))}</span><span class="actions">{switch}</span></li>')
        rows = ''.join(row(l['name'], l['id'], l['enabled'], l['media_type']) for l in db.libraries())
        if service.jellyfin is not None:
            rows += row('Jellyfin (asked for in Miru)', 'jellyfin', True, 'episodes', switchable=False)
        return f'<section id="libraries"><h2>Libraries</h2><ul class="jobs">{rows}</ul></section>'

    def sections():
        now = time.time()
        return status_section(now) + queue_section(now) + failures_section(now) + libraries_section(now)

    # Routes (no OpenAPI: they're the page's own)

    @app.get('/ui', include_in_schema=False)
    def ui(user: str = Depends(gate)):
        token = csrf_token(config.ui_secret, user)
        body = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="csrf-token" content="{token}"><title>Kaku</title><link rel="stylesheet" href="/ui/static/ui.css"></head>
<body><header><h1>Kaku <span class="quiet">書く</span></h1><span class="quiet">{escape(user)}</span></header>
<main id="sections">{sections()}</main>
<script src="/ui/static/ui.js"></script></body></html>'''
        return page(body)

    @app.get('/ui/sections', include_in_schema=False)
    def ui_sections(user: str = Depends(gate)):
        """The page's sections again, for its refresh every few seconds."""
        return page(sections())

    def same_origin(request: Request):
        """Changes come only from the page itself: its Origin is this address (behind the proxy,
        the forwarded host)."""
        origin = request.headers.get('origin', '')
        host = request.headers.get('x-forwarded-host') or request.headers.get('host', '')
        if not origin or urlsplit(origin).netloc != host:
            raise HTTPException(403, 'Changes come from Kaku’s own page only.')

    def find(item_id, episode_id):
        job = db.job(item_id, episode_id)
        if job is None:
            raise HTTPException(404, 'Kaku has no such job.')
        return job

    @app.post('/ui/api/action', include_in_schema=False)
    def ui_action(change: Action, request: Request, user: str = Depends(gate)):
        same_origin(request)
        if not csrf_valid(config.ui_secret, user, request.headers.get('x-csrf-token', '')):
            raise HTTPException(403, 'The page is out of date: reload it.')
        now = time.time()
        title = ''
        if change.action in ('next', 'cancel', 'retry'):
            title = find(change.itemId, change.episodeId)['title']
            done = {'next': db.move_to_front, 'cancel': db.cancel, 'retry': db.requeue}[change.action](
                change.itemId, change.episodeId, now)
            if not done:
                raise HTTPException(409, 'That job has moved on: the page shows it as it is now.')
            if change.action != 'cancel':
                service.worker.wake.set()
        elif change.action in ('library-on', 'library-off'):
            library = next((l for l in db.libraries() if l['id'] == change.libraryId), None)
            if library is None:
                raise HTTPException(404, 'No such library.')
            db.set_enabled(library['id'], change.action == 'library-on')
            service.poller.wake.set()
            title = library['name']
        elif change.action == 'poll':
            service.poller.wake.set()
        elif change.action in ('pause', 'resume'):
            db.set_paused(change.action == 'pause')
            if change.action == 'resume':
                service.worker.wake.set()
        else:
            raise HTTPException(400, 'Unknown action.')
        db.record(user, change.action, title, now)
        return page(sections())

    @app.get('/ui/static/{name}', include_in_schema=False)
    def ui_static(name: str, user: str = Depends(gate)):
        types = {'ui.css': 'text/css; charset=utf-8', 'ui.js': 'text/javascript; charset=utf-8'}
        if name not in types:
            raise HTTPException(404)
        with open(os.path.join(STATIC, name), encoding='utf-8') as file:
            return page(file.read(), media_type=types[name])
