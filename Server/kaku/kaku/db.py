"""Kaku's SQLite database: which libraries are on, the job queue, and the transcripts made."""
from __future__ import annotations

import sqlite3
import threading
import time

from . import is_current

# Job priorities, highest first.
NOW, NEW, BACKLOG = 0, 1, 2
PRIORITY_NAMES = {NOW: 'now', NEW: 'new', BACKLOG: 'backlog'}
# A job that fails is tried again later, up to this many times in all.
MAX_ATTEMPTS = 3

SCHEMA = '''
CREATE TABLE IF NOT EXISTS library (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, media_type TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS job (
    item_id TEXT NOT NULL, episode_id TEXT NOT NULL, library_id TEXT NOT NULL, title TEXT NOT NULL,
    priority INTEGER NOT NULL, added_at REAL NOT NULL, queued_at REAL NOT NULL,
    state TEXT NOT NULL,              -- queued, running, done, failed, cancelled (1.9: on the web page)
    progress REAL NOT NULL DEFAULT 0, -- 0…1 while running
    error TEXT, fingerprint TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
    not_before REAL NOT NULL DEFAULT 0, started_at REAL, finished_at REAL,
    PRIMARY KEY (item_id, episode_id));
CREATE TABLE IF NOT EXISTS transcript (
    item_id TEXT NOT NULL, episode_id TEXT NOT NULL, path TEXT NOT NULL, fingerprint TEXT NOT NULL,
    model TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY (item_id, episode_id));
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
-- A failed job's last lines and traceback, kept 14 days (1.9, the web page's Problems).
CREATE TABLE IF NOT EXISTS job_log (
    item_id TEXT NOT NULL, episode_id TEXT NOT NULL, at REAL NOT NULL, text TEXT NOT NULL,
    PRIMARY KEY (item_id, episode_id));
-- Each library's shows (podcasts) or books, as Audiobookshelf lists them (1.10, the web page).
CREATE TABLE IF NOT EXISTS show (item_id TEXT PRIMARY KEY, library_id TEXT NOT NULL, title TEXT NOT NULL);
-- The web page's rules (1.10): a show's or book's mode (skip, pause, high, low), or a library's
-- default (item_id '': new-only, no backlog).
CREATE TABLE IF NOT EXISTS rule (
    library_id TEXT NOT NULL, item_id TEXT NOT NULL, mode TEXT NOT NULL, PRIMARY KEY (library_id, item_id));
-- Settings changed on the web page (1.11), over the environment's.
CREATE TABLE IF NOT EXISTS setting (key TEXT PRIMARY KEY, value TEXT NOT NULL);
-- Changes made on the web page (/ui): who, what and when (1.9).
CREATE TABLE IF NOT EXISTS audit (at REAL NOT NULL, user TEXT NOT NULL, action TEXT NOT NULL, detail TEXT NOT NULL);
'''

# Claim order: "now" first in the order asked; "new" oldest first; the backlog newest first.
ORDER = '''priority, CASE priority WHEN 0 THEN queued_at WHEN 1 THEN added_at ELSE -added_at END'''


class Database:
    def __init__(self, path):
        self.connection = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.connection.row_factory = sqlite3.Row
        self.connection.execute('PRAGMA journal_mode=WAL')
        self.connection.executescript(SCHEMA)
        self.lock = threading.Lock()
        # A job left running by a stop or crash is queued again.
        self.execute("UPDATE job SET state = 'queued', progress = 0 WHERE state = 'running'")

    def execute(self, sql, arguments=()):
        with self.lock:
            return self.connection.execute(sql, arguments).fetchall()

    # Libraries

    def sync_libraries(self, libraries):
        """Records Audiobookshelf's libraries (new ones start off) and forgets removed ones."""
        with self.lock:
            ids = [library['id'] for library in libraries]
            for library in libraries:
                self.connection.execute(
                    'INSERT INTO library (id, name, media_type) VALUES (?, ?, ?) '
                    'ON CONFLICT(id) DO UPDATE SET name = excluded.name, media_type = excluded.media_type',
                    (library['id'], library['name'], library['mediaType']))
            marks = ','.join('?' * len(ids))
            self.connection.execute(f'DELETE FROM library WHERE id NOT IN ({marks})', ids)

    def libraries(self):
        return [dict(row) | {'enabled': bool(row['enabled'])} for row in self.execute('SELECT * FROM library ORDER BY name')]

    def set_enabled(self, library_id, enabled):
        self.execute('UPDATE library SET enabled = ? WHERE id = ?', (int(enabled), library_id))
        if not enabled:
            self.execute("DELETE FROM job WHERE library_id = ? AND state IN ('queued', 'failed')", (library_id,))

    def enabled_libraries(self):
        return [row['id'] for row in self.execute('SELECT id FROM library WHERE enabled = 1')]

    # Jobs

    def offer(self, episode, priority, model, now=None, force=False):
        """Queues `episode` unless it already has a current transcript (`is_current`: this audio, this
        pipeline, by whichever model; `force` queues it anyway: Transcribe Again), or is already
        queued or running. A queued job only ever
        moves up in priority; a failed one is tried again only when asked for (`NOW`) or when its
        audio changed. True if queued or moved up."""
        now = now or time.time()
        key = (episode.item_id, episode.episode_id)
        with self.lock:
            done = self.connection.execute('SELECT fingerprint, model FROM transcript WHERE item_id = ? AND episode_id = ?',
                                           key).fetchone()
            if not force and done and is_current(done['model'], done['fingerprint'], episode.fingerprint):
                return False
            job = self.connection.execute('SELECT * FROM job WHERE item_id = ? AND episode_id = ?', key).fetchone()
            if job and job['fingerprint'] == episode.fingerprint:
                # Failed or cancelled: only when asked for again (the apps, Transcribe Again, the page).
                if job['state'] == 'running' or (job['state'] in ('failed', 'cancelled') and priority != NOW):
                    return False
                if job['state'] == 'queued':
                    if priority >= job['priority']:
                        return False
                    self.connection.execute('UPDATE job SET priority = ?, queued_at = ?, not_before = 0 '
                                            'WHERE item_id = ? AND episode_id = ?', (priority, now, *key))
                    return True
            self.connection.execute(
                'INSERT OR REPLACE INTO job (item_id, episode_id, library_id, title, priority, added_at, queued_at, state, fingerprint) '
                "VALUES (?, ?, ?, ?, ?, ?, ?, 'queued', ?)",
                (*key, episode.library_id, episode.title, priority, episode.added_at, now, episode.fingerprint))
            return True

    def claim(self, now=None):
        """The next job to run, marked running; None when nothing is due. A paused show's jobs
        wait, unless one was asked for."""
        now = now or time.time()
        with self.lock:
            row = self.connection.execute(
                f"SELECT * FROM job WHERE state = 'queued' AND not_before <= ? AND (priority = {NOW} OR item_id NOT IN "
                f"(SELECT item_id FROM rule WHERE mode = 'pause')) ORDER BY {ORDER} LIMIT 1", (now,)).fetchone()
            if row is None:
                return None
            self.connection.execute(
                "UPDATE job SET state = 'running', progress = 0, started_at = ?, attempts = attempts + 1 "
                'WHERE item_id = ? AND episode_id = ?', (now, row['item_id'], row['episode_id']))
            return dict(row) | {'attempts': row['attempts'] + 1}

    def set_progress(self, job, progress):
        self.execute('UPDATE job SET progress = ? WHERE item_id = ? AND episode_id = ?',
                     (progress, job['item_id'], job['episode_id']))

    def finish(self, job, path, model, now=None):
        now = now or time.time()
        with self.lock:
            self.connection.execute(
                "UPDATE job SET state = 'done', progress = 1, error = NULL, finished_at = ? WHERE item_id = ? AND episode_id = ?",
                (now, job['item_id'], job['episode_id']))
            self.connection.execute(
                'INSERT OR REPLACE INTO transcript (item_id, episode_id, path, fingerprint, model, created_at) VALUES (?, ?, ?, ?, ?, ?)',
                (job['item_id'], job['episode_id'], path, job['fingerprint'], model, now))

    def fail(self, job, error, now=None, permanent=False):
        """Queues the job again in 10, then 20 minutes; after MAX_ATTEMPTS it stays failed."""
        now = now or time.time()
        final = permanent or job['attempts'] >= MAX_ATTEMPTS
        self.execute(
            'UPDATE job SET state = ?, error = ?, progress = 0, not_before = ?, finished_at = ? WHERE item_id = ? AND episode_id = ?',
            ('failed' if final else 'queued', str(error)[:500], now + 600 * job['attempts'], now, job['item_id'], job['episode_id']))

    # The web page's queue actions (1.9). Each returns whether it changed anything.

    def move_to_front(self, item_id, episode_id, now=None):
        """A queued job goes next: asked-for priority, after the ones already asked for."""
        return bool(self.execute(
            "UPDATE job SET priority = ?, queued_at = ?, not_before = 0 WHERE item_id = ? AND episode_id = ? "
            "AND state = 'queued' RETURNING item_id", (NOW, now or time.time(), item_id, episode_id)))

    def requeue(self, item_id, episode_id, now=None):
        """A failed or cancelled job is queued again, next, with its tries counted afresh."""
        return bool(self.execute(
            "UPDATE job SET state = 'queued', priority = ?, queued_at = ?, not_before = 0, attempts = 0, error = NULL, "
            "progress = 0 WHERE item_id = ? AND episode_id = ? AND state IN ('failed', 'cancelled') RETURNING item_id",
            (NOW, now or time.time(), item_id, episode_id)))

    def cancel(self, item_id, episode_id, now=None):
        """A queued job leaves the queue; the poller doesn't queue it again until its audio changes."""
        return bool(self.execute(
            "UPDATE job SET state = 'cancelled', finished_at = ? WHERE item_id = ? AND episode_id = ? AND state = 'queued' "
            'RETURNING item_id', (now or time.time(), item_id, episode_id)))

    def cancel_running(self, item_id, episode_id, now=None):
        """The running job, stopped on the web page: cancelled like a queued one."""
        self.execute("UPDATE job SET state = 'cancelled', progress = 0, finished_at = ? "
                     "WHERE item_id = ? AND episode_id = ? AND state = 'running'", (now or time.time(), item_id, episode_id))

    # Shows and rules (1.10)

    MODES = ('skip', 'pause', 'high', 'low')

    def sync_shows(self, library_id, titles):
        """A library's shows or books as its last listing had them ({item id: title})."""
        with self.lock:
            for item_id, title in titles.items():
                self.connection.execute(
                    'INSERT INTO show (item_id, library_id, title) VALUES (?, ?, ?) '
                    'ON CONFLICT(item_id) DO UPDATE SET library_id = excluded.library_id, title = excluded.title',
                    (item_id, library_id, title))
            marks = ','.join('?' * len(titles))
            self.connection.execute(f'DELETE FROM show WHERE library_id = ? AND item_id NOT IN ({marks})',
                                    (library_id, *titles))

    def shows(self, library_id):
        """A library's shows or books by title, each with its job counts and rule."""
        rows = self.execute(
            "SELECT show.item_id, show.title, rule.mode, "
            "SUM(job.state = 'done') AS done, SUM(job.state IN ('queued', 'running')) AS waiting, "
            "SUM(job.state = 'failed') AS failed FROM show "
            "LEFT JOIN rule ON rule.library_id = show.library_id AND rule.item_id = show.item_id "
            "LEFT JOIN job ON job.item_id = show.item_id "
            "WHERE show.library_id = ? GROUP BY show.item_id ORDER BY show.title COLLATE NOCASE", (library_id,))
        return [dict(row) | {key: row[key] or 0 for key in ('done', 'waiting', 'failed')} for row in rows]

    def rules(self, library_id):
        """{item id: mode} for a library; '' holds its default ('new-only')."""
        return {row['item_id']: row['mode'] for row in self.execute('SELECT * FROM rule WHERE library_id = ?', (library_id,))}

    def paused_items(self):
        return {row['item_id'] for row in self.execute("SELECT item_id FROM rule WHERE mode = 'pause'")}

    def set_rule(self, library_id, item_id, mode):
        """A show's or book's mode (None: as the library does), applied to what's already queued:
        skip removes its waiting and failed jobs; high and low move its queued jobs between new and
        backlog (asked-for jobs stay first)."""
        if mode is None:
            self.execute('DELETE FROM rule WHERE library_id = ? AND item_id = ?', (library_id, item_id))
        else:
            self.execute('INSERT OR REPLACE INTO rule (library_id, item_id, mode) VALUES (?, ?, ?)', (library_id, item_id, mode))
        if mode == 'skip':
            self.execute(f"DELETE FROM job WHERE item_id = ? AND state IN ('queued', 'failed') AND priority != {NOW}", (item_id,))
        elif mode in ('high', 'low'):
            old, new = (BACKLOG, NEW) if mode == 'high' else (NEW, BACKLOG)
            self.execute("UPDATE job SET priority = ? WHERE item_id = ? AND state = 'queued' AND priority = ?", (new, item_id, old))

    def set_new_only(self, library_id, new_only):
        """A library without its backlog: only new episodes are queued (a high-priority show's too);
        its backlog jobs already waiting go."""
        if new_only:
            self.execute("INSERT OR REPLACE INTO rule (library_id, item_id, mode) VALUES (?, '', 'new-only')", (library_id,))
            self.execute(
                f"DELETE FROM job WHERE library_id = ? AND state = 'queued' AND priority = {BACKLOG} AND item_id NOT IN "
                "(SELECT item_id FROM rule WHERE library_id = ? AND mode = 'high')", (library_id, library_id))
        else:
            self.execute("DELETE FROM rule WHERE library_id = ? AND item_id = ''", (library_id,))

    # Settings (1.11)

    def settings(self):
        return {row['key']: row['value'] for row in self.execute('SELECT * FROM setting')}

    def set_setting(self, key, value):
        """`value` None: back to the environment's."""
        if value is None:
            self.execute('DELETE FROM setting WHERE key = ?', (key,))
        else:
            self.execute('INSERT OR REPLACE INTO setting (key, value) VALUES (?, ?)', (key, value))

    # A failed job's log

    LOG_DAYS = 14

    def save_log(self, item_id, episode_id, text, now=None):
        now = now or time.time()
        self.execute('INSERT OR REPLACE INTO job_log (item_id, episode_id, at, text) VALUES (?, ?, ?, ?)',
                     (item_id, episode_id, now, text))
        self.execute('DELETE FROM job_log WHERE at < ?', (now - self.LOG_DAYS * 86400,))

    def job_log(self, item_id, episode_id, now=None):
        rows = self.execute('SELECT * FROM job_log WHERE item_id = ? AND episode_id = ? AND at >= ?',
                            (item_id, episode_id, (now or time.time()) - self.LOG_DAYS * 86400))
        return dict(rows[0]) if rows else None

    def record(self, user, action, detail, now=None):
        self.execute('INSERT INTO audit (at, user, action, detail) VALUES (?, ?, ?, ?)',
                     (now or time.time(), user, action, detail))

    def changes(self, limit=10):
        return [dict(row) for row in self.execute('SELECT * FROM audit ORDER BY at DESC LIMIT ?', (limit,))]

    @property
    def paused(self):
        """Stop after this one: no new job starts; the running one finishes."""
        return self.meta('paused') == '1'

    def set_paused(self, paused):
        self.set_meta('paused', '1' if paused else '0')

    def job(self, item_id, episode_id):
        rows = self.execute('SELECT * FROM job WHERE item_id = ? AND episode_id = ?', (item_id, episode_id))
        return dict(rows[0]) if rows else None

    def queue(self):
        """Running and queued jobs in the order they'll run."""
        return [dict(row) for row in self.execute(
            f"SELECT * FROM job WHERE state IN ('running', 'queued') ORDER BY state = 'queued', {ORDER}")]

    def position(self, item_id, episode_id):
        """0 for the running job, 1 for the next one…; None if it's not waiting."""
        for index, job in enumerate(self.queue()):
            if (job['item_id'], job['episode_id']) == (item_id, episode_id):
                return index
        return None

    def counts(self):
        return {row['state']: row['n'] for row in self.execute('SELECT state, COUNT(*) AS n FROM job GROUP BY state')}

    def library_counts(self):
        """Each library's jobs by state, and when it last finished one: {library_id: {'counts', 'last'}}."""
        stats = {}
        for row in self.execute(
                "SELECT library_id, state, COUNT(*) AS n, MAX(CASE WHEN state = 'done' THEN finished_at END) AS last "
                'FROM job GROUP BY library_id, state'):
            entry = stats.setdefault(row['library_id'], {'counts': {}, 'last': None})
            entry['counts'][row['state']] = row['n']
            if row['last'] is not None:
                entry['last'] = row['last']
        return stats

    def average_seconds(self, limit=20):
        """How long the last `limit` finished jobs took, on average; None before any."""
        rows = self.execute(
            "SELECT finished_at - started_at AS took FROM job WHERE state = 'done' AND started_at IS NOT NULL "
            'AND finished_at > started_at ORDER BY finished_at DESC LIMIT ?', (limit,))
        return sum(row['took'] for row in rows) / len(rows) if rows else None

    def failed(self, limit=20):
        return [dict(row) for row in self.execute(
            "SELECT * FROM job WHERE state = 'failed' ORDER BY finished_at DESC LIMIT ?", (limit,))]

    # Transcripts

    def transcript(self, item_id, episode_id):
        rows = self.execute('SELECT * FROM transcript WHERE item_id = ? AND episode_id = ?', (item_id, episode_id))
        return dict(rows[0]) if rows else None

    # Meta

    def set_meta(self, key, value):
        self.execute('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', (key, str(value)))

    def meta(self, key):
        rows = self.execute('SELECT value FROM meta WHERE key = ?', (key,))
        return rows[0]['value'] if rows else None
