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

from urllib.parse import quote, urlsplit

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import Response
from pydantic import BaseModel

from . import VERSION
from . import settings as tunables
from .db import PRIORITY_NAMES
from .logs import RING

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
    # A rule's mode (normal, high, low, pause, skip) or a library's backlog (on, off).
    value: str = ''
    # The page the change came from ('library:<id>' for a library's shows): which sections to answer with.
    view: str = ''
    # A setting's key (1.11).
    key: str = ''


MODE_NAMES = {None: 'normal', 'high': 'high priority', 'low': 'low priority', 'pause': 'paused', 'skip': 'skipped'}
MODE_BUTTONS = (('normal', 'Normal'), ('high', 'High'), ('low', 'Low'), ('pause', 'Pause'), ('skip', 'Skip'))


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
            button('Stop after this one', 'pause', confirm='Let the current job finish, then start nothing new?')
        ) + '<a class="button" href="/ui/logs">Kaku’s log</a><a class="button" href="/ui/settings">Settings</a><a class="button" href="/ui/stats">Stats</a>'
        changes = db.changes(5)
        recent = ''.join(f'<li><span class="title">{escape(change["action"])} · {escape(change["detail"])}</span>'
                         f'<span class="detail">{escape(change["user"])} · {escape(ago(change["at"], now))}</span></li>'
                         for change in changes)
        recent = f'<h3>Recent changes</h3><ul class="jobs">{recent}</ul>' if changes else ''
        return (f'<section id="status"><h2>Status</h2><dl>{html}</dl>{problems}'
                f'<p class="controls">{controls}</p>{recent}</section>')

    def job_row(job, now, position=None, paused=frozenset()):
        progress = f' · {round(job["progress"] * 100)}%' if job['state'] == 'running' else ''
        if job['state'] == 'queued' and job['item_id'] in paused and job['priority'] != 0:
            progress += ' · show paused'
        target = {'item': job['item_id'], 'episode': job['episode_id']}
        actions = ''
        if job['state'] == 'queued':
            actions = ((button('Next', 'next', **target) if position else '')
                       + button('Cancel', 'cancel', confirm=f'Take “{job["title"]}” out of the queue?', **target))
        elif job['state'] == 'running':
            actions = button('Cancel now', 'cancel-now', confirm=f'Stop transcribing “{job["title"]}”? What’s done so far is lost.',
                             **target)
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
        paused = db.paused_items()
        queued_html = (f'<ol class="jobs">{"".join(job_row(job, now, index, paused) for index, job in enumerate(shown))}</ol>{rest}'
                       if queued else '<p class="quiet">The queue is empty.</p>')
        return (f'<section id="queue"><h2>Now transcribing</h2>{now_html}'
                f'<h2>Queue ({len(queued)}{escape(estimate)})</h2>{queued_html}</section>')

    def log_link(job):
        if not db.job_log(job['item_id'], job['episode_id']):
            return ''
        return (f'<a class="button" href="/ui/log?item={quote(job["item_id"], safe="")}'
                f'&amp;episode={quote(job["episode_id"], safe="")}">Log</a>')

    def failures_section(now):
        failed = db.failed()
        if not failed:
            return '<section id="failures"><h2>Problems</h2><p class="quiet">None.</p></section>'
        rows = ''.join(
            f'<li><span class="title">{escape(job["title"])}</span>'
            f'<span class="detail">{escape(ago(job["finished_at"], now))} · {job["attempts"]} '
            f'{"try" if job["attempts"] == 1 else "tries"}</span>'
            f'<span class="actions">{log_link(job)}{button("Try again", "retry", item=job["item_id"], episode=job["episode_id"])}</span>'
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
            new_only = switchable and db.rules(library_id).get('') == 'new-only'
            state = ('on, new only' if new_only else 'on') if enabled else 'off'
            switch = ''
            if switchable:
                shows = 'Books' if kind == 'book' else 'Shows'
                switch = (f'<a class="button" href="/ui/library?id={quote(library_id, safe="")}">{shows}</a>'
                          + (button('Include backlog', 'library-backlog', library=library_id, value='on') if new_only else
                             button('New only', 'library-backlog', library=library_id, value='off',
                                    confirm=f'Only new episodes in “{name}”? Its waiting backlog is removed; transcripts stay.'))
                          + (button('Turn off', 'library-off', library=library_id,
                                    confirm=f'Turn off “{name}”? Its waiting and failed jobs are removed; transcripts stay.')
                             if enabled else button('Turn on', 'library-on', library=library_id)))
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

    def library_or_404(library_id):
        library = next((l for l in db.libraries() if l['id'] == library_id), None)
        if library is None:
            raise HTTPException(404, 'No such library.')
        return library

    def library_sections(library_id):
        """A library's shows or books, each with its counts and mode (1.10)."""
        library = library_or_404(library_id)
        shows = db.shows(library_id)
        kind = 'books' if library['media_type'] == 'book' else 'shows'
        new_only = db.rules(library_id).get('') == 'new-only'
        note = (f'<p class="quiet">{"New episodes only" if new_only else "New episodes first, then the backlog"}'
                f'{"" if library["enabled"] else " · this library is off"}. High: first among new ones (and its backlog '
                f'even when new only). Low: with the backlog. Pause: waits until resumed. Skip: never transcribed.</p>')
        if not shows:
            body = f'<p class="quiet">No {kind} yet: they appear after Kaku next checks Audiobookshelf.</p>'
        else:
            def show_row(show):
                mode = show['mode']
                buttons = ''.join(button(label, 'rule', library=library_id, item=show['item_id'], value=value,
                                         **({'confirm': f'Skip “{show["title"]}”? Its waiting jobs are removed; transcripts stay.'}
                                            if value == 'skip' else {}))
                                  for value, label in MODE_BUTTONS if value != (mode or 'normal'))
                return (f'<li><span class="title">{escape(show["title"])}</span>'
                        f'<span class="detail">{escape(MODE_NAMES.get(mode, mode))} · {show["done"]} transcribed · '
                        f'{show["waiting"]} waiting · {show["failed"]} failed</span><span class="actions">{buttons}</span></li>')
            body = f'<ul class="jobs">{"".join(show_row(show) for show in shows)}</ul>'
        return f'<section id="shows"><h2>{escape(library["name"])}: {kind}</h2>{note}{body}</section>'

    # Settings (1.11)

    last_check = {}

    def settings_sections():
        stored = db.settings()
        rows = ''
        for setting in tunables.SETTINGS:
            value = tunables.value_of(setting, stored.get(setting.key), config)
            if setting.key == 'model':
                value = service.worker.next_model or service.transcriber.name
            source = 'set here' if setting.key in stored else 'from the environment'
            field = f'setting-{setting.key}'
            if setting.kind == 'model':
                options = ''.join(
                    f'<option value="{escape(name)}"{" selected" if name == value else ""}>{escape(name)}'
                    f'{"" if on_disk else " (downloads on first use)"}</option>'
                    for name, on_disk in tunables.model_choices(config.models_dir, value))
                control = f'<select id="{field}">{options}</select>'
                check = button('Check', 'check-model', input=field)
            else:
                shown = '' if value is None else ('none' if value == '' and setting.key == 'prompt' else str(value))
                kind = 'number' if setting.kind == 'int' else 'text'
                limits = f' min="{setting.minimum}" max="{setting.maximum}"' if setting.kind == 'int' else f' maxlength="{setting.maximum}"'
                control = f'<input id="{field}" type="{kind}" value="{escape(shown)}"{limits}>'
                check = ''
            reset = button('Use the environment’s', 'setting-reset', key=setting.key) if setting.key in stored else ''
            note = f'<span class="detail">{escape(source)} · takes effect {escape(setting.when)}</span>'
            help_text = f'<span class="help">{escape(setting.help)}</span>' if setting.help else ''
            rows += (f'<li><label class="title" for="{field}">{escape(setting.label)}</label>{note}'
                     f'<span class="actions">{control}{button("Save", "setting", key=setting.key, input=field)}{check}{reset}</span>'
                     f'{help_text}</li>')
        pending = (f'<p class="quiet">Switching to {escape(service.worker.next_model)} at the next job.</p>'
                   if service.worker.next_model and service.worker.next_model != service.transcriber.name else '')
        checked = (f'<p class="{"quiet" if last_check["ok"] else "problem"}">{escape(last_check["message"])}</p>'
                   if last_check else '')
        return (f'<section id="settings"><h2>Settings</h2>{pending}{checked}<ul class="jobs settings">{rows}</ul>'
                f'<p class="quiet">Addresses, keys and folders stay in the environment (the compose file).</p></section>')

    # Stats (1.12)

    def stats_sections(now=None):
        now = now or time.time()
        days = 30
        start = time.mktime(time.localtime(now)[:3] + (0, 0, 0, 0, 0, -1)) - (days - 1) * 86400
        history = db.history(since=start)
        by_day = {}
        for row in history:
            day = time.strftime('%Y-%m-%d', time.localtime(row['at']))
            hours, count = by_day.get(day, (0.0, 0))
            by_day[day] = (hours + row['duration'] / 3600, count + 1)
        top = max([hours for hours, _ in by_day.values()] or [0]) or 1
        day_rows = ''
        for index in range(days):
            day = time.strftime('%Y-%m-%d', time.localtime(start + index * 86400 + 43200))
            hours, count = by_day.get(day, (0.0, 0))
            day_rows += (f'<tr><td>{escape(day[5:])}</td><td><meter min="0" max="{top:.3f}" value="{hours:.3f}"></meter></td>'
                         f'<td>{hours:.1f} h</td><td class="quiet">{count}</td></tr>')
        total_hours = sum(hours for hours, _ in by_day.values())
        names = {l['id']: l['name'] for l in db.libraries()} | {'jellyfin': 'Jellyfin (asked for in Miru)'}
        recent = {}
        for row in history:
            recent[row['library_id']] = recent.get(row['library_id'], 0) + row['duration'] / 3600
        library_rows = ''.join(
            f'<tr><td>{escape(names.get(library_id, library_id or "—"))}</td><td>{hours:.1f} h</td>'
            f'<td class="quiet">{count}</td><td>{recent.get(library_id, 0):.1f} h</td></tr>'
            for library_id, (hours, count) in sorted(db.library_totals().items(), key=lambda item: -item[1][0]))
        speed_rows = ''.join(
            f'<li><span class="title">{escape(model.split("/")[0])}</span><span class="detail">{factor:.0f}× real time · '
            f'about {duration(3600 / factor)} per hour of audio · last {count} timed</span></li>'
            for model, (factor, count) in db.speed().items())
        return (f'<section id="stats"><h2>Last {days} days: {total_hours:.1f} h of audio</h2>'
                f'<table class="days"><tr><th>Day</th><th></th><th>Audio</th><th>Jobs</th></tr>{day_rows}</table>'
                f'<h2>Libraries</h2>' + (f'<table><tr><th>Library</th><th>All</th><th>Transcripts</th><th>Last {days} days</th></tr>'
                                          f'{library_rows}</table>' if library_rows else '<p class="quiet">Nothing transcribed yet.</p>')
                + f'<h2>Speed</h2>' + (f'<ul class="jobs">{speed_rows}</ul>' if speed_rows else '<p class="quiet">Not timed yet.</p>')
                + '</section>')

    def view_sections(view):
        if view == 'stats':
            return stats_sections()
        if view == 'settings':
            return settings_sections()
        return library_sections(view.split(':', 1)[1]) if view.startswith('library:') else sections()

    # Routes (no OpenAPI: they're the page's own)

    def shell(user, content, view='', title='Kaku', back=None):
        """A page whose `#sections` the script refreshes (from `view`) and redraws after a change."""
        token = csrf_token(config.ui_secret, user)
        link = f'<a href="{back}">Back</a>' if back else f'<span class="quiet">{escape(user)}</span>'
        body = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="csrf-token" content="{token}"><title>{escape(title)}</title><link rel="stylesheet" href="/ui/static/ui.css"></head>
<body><header><h1>Kaku <span class="quiet">書く</span></h1>{link}</header>
<main id="sections" data-view="{escape(view)}">{content}</main>
<script src="/ui/static/ui.js"></script></body></html>'''
        return page(body)

    @app.get('/ui', include_in_schema=False)
    def ui(user: str = Depends(gate)):
        return shell(user, sections())

    @app.get('/ui/stats', include_in_schema=False)
    def ui_stats(user: str = Depends(gate)):
        return shell(user, stats_sections(), view='stats', title='Stats · Kaku', back='/ui')

    @app.get('/ui/settings', include_in_schema=False)
    def ui_settings(user: str = Depends(gate)):
        return shell(user, settings_sections(), view='settings', title='Settings · Kaku', back='/ui')

    @app.get('/ui/library', include_in_schema=False)
    def ui_library(id: str, user: str = Depends(gate)):
        """A library's shows or books and their rules."""
        library = library_or_404(id)
        return shell(user, library_sections(id), view=f'library:{id}', title=f'{library["name"]} · Kaku', back='/ui')

    @app.get('/ui/sections', include_in_schema=False)
    def ui_sections(view: str = '', user: str = Depends(gate)):
        """The page's sections again, for its refresh every few seconds."""
        return page(view_sections(view))

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
        elif change.action == 'cancel-now':
            title = find(change.itemId, change.episodeId)['title']
            if not service.worker.cancel_running(change.itemId, change.episodeId):
                raise HTTPException(409, 'That job isn’t the one running any more.')
        elif change.action in ('library-on', 'library-off'):
            library = next((l for l in db.libraries() if l['id'] == change.libraryId), None)
            if library is None:
                raise HTTPException(404, 'No such library.')
            db.set_enabled(library['id'], change.action == 'library-on')
            service.poller.wake.set()
            title = library['name']
        elif change.action == 'rule':
            library_or_404(change.libraryId)
            if change.value not in ('normal', *db.MODES):
                raise HTTPException(400, 'Unknown mode.')
            show = next((show for show in db.shows(change.libraryId) if show['item_id'] == change.itemId), None)
            if show is None:
                raise HTTPException(404, 'No such show or book in this library.')
            db.set_rule(change.libraryId, change.itemId, None if change.value == 'normal' else change.value)
            title = f'{show["title"]}: {change.value}'
            service.worker.wake.set()
        elif change.action == 'library-backlog':
            library = library_or_404(change.libraryId)
            if change.value not in ('on', 'off'):
                raise HTTPException(400, 'Backlog is on or off.')
            db.set_new_only(library['id'], change.value == 'off')
            service.poller.wake.set()
            title = f'{library["name"]}: backlog {change.value}'
        elif change.action in ('setting', 'setting-reset'):
            setting = tunables.BY_KEY.get(change.key)
            if setting is None:
                raise HTTPException(400, 'Unknown setting.')
            if change.action == 'setting':
                try:
                    stored = tunables.parse(setting, change.value, config.models_dir, service.transcriber.name)
                except ValueError as error:
                    raise HTTPException(400, str(error)) from None
                db.set_setting(setting.key, stored)
            else:
                stored = None
                db.set_setting(setting.key, None)
            tunables.apply(service, setting.key, tunables.value_of(setting, stored, config))
            last_check.clear()
            title = f'{setting.label}: {stored if stored is not None else "from the environment"}'
        elif change.action == 'check-model':
            ok, message = tunables.check_model(change.value.strip(), config.models_dir)
            last_check.update(ok=ok, message=message)
            title = change.value.strip()
        elif change.action == 'poll':
            service.poller.wake.set()
        elif change.action in ('pause', 'resume'):
            db.set_paused(change.action == 'pause')
            if change.action == 'resume':
                service.worker.wake.set()
        else:
            raise HTTPException(400, 'Unknown action.')
        db.record(user, change.action, title, now)
        return page(view_sections(change.view))

    def text_page(title, text, user, back='/ui'):
        body = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape(title)} · Kaku</title><link rel="stylesheet" href="/ui/static/ui.css"></head>
<body><header><h1>{escape(title)}</h1><a href="{back}">Back</a></header>
<pre class="log">{escape(text) or 'Nothing yet.'}</pre></body></html>'''
        return page(body)

    @app.get('/ui/log', include_in_schema=False)
    def ui_job_log(item: str, episode: str = '', user: str = Depends(gate)):
        """A failed job's last lines and traceback (kept 14 days), keys taken out."""
        saved = db.job_log(item, episode)
        job = db.job(item, episode)
        if saved is None:
            raise HTTPException(404, 'No log kept for this job (they’re kept 14 days).')
        return text_page(f'Log: {job["title"] if job else item}', saved['text'], user)

    @app.get('/ui/logs', include_in_schema=False)
    def ui_logs(user: str = Depends(gate)):
        """Kaku's last lines (in memory: since it started, up to 500), newest last."""
        return text_page('Kaku’s log', '\n'.join(RING.lines), user)

    @app.get('/ui/static/{name}', include_in_schema=False)
    def ui_static(name: str, user: str = Depends(gate)):
        types = {'ui.css': 'text/css; charset=utf-8', 'ui.js': 'text/javascript; charset=utf-8'}
        if name not in types:
            raise HTTPException(404)
        with open(os.path.join(STATIC, name), encoding='utf-8') as file:
            return page(file.read(), media_type=types[name])
