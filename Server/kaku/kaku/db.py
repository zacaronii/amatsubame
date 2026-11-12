"""Kaku's SQLite database: which libraries are on, the job queue, and the transcripts made."""
from __future__ import annotations

import sqlite3
import threading
import time

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
    state TEXT NOT NULL,              -- queued, running, done, failed
    progress REAL NOT NULL DEFAULT 0, -- 0…1 while running
    error TEXT, fingerprint TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
    not_before REAL NOT NULL DEFAULT 0, started_at REAL, finished_at REAL,
    PRIMARY KEY (item_id, episode_id));
CREATE TABLE IF NOT EXISTS transcript (
    item_id TEXT NOT NULL, episode_id TEXT NOT NULL, path TEXT NOT NULL, fingerprint TEXT NOT NULL,
    model TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY (item_id, episode_id));
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
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

    def offer(self, episode, priority, model, now=None):
        """Queues `episode` unless it already has a transcript of this audio by this model, or is
        already queued or running. A queued job only ever moves up in priority; a failed one is
        tried again only when asked for (`NOW`) or when its audio changed. True if queued or moved up."""
        now = now or time.time()
        key = (episode.item_id, episode.episode_id)
        with self.lock:
            done = self.connection.execute('SELECT fingerprint, model FROM transcript WHERE item_id = ? AND episode_id = ?',
                                           key).fetchone()
            if done and (done['fingerprint'], done['model']) == (episode.fingerprint, model):
                return False
            job = self.connection.execute('SELECT * FROM job WHERE item_id = ? AND episode_id = ?', key).fetchone()
            if job and job['fingerprint'] == episode.fingerprint:
                if job['state'] == 'running' or (job['state'] == 'failed' and priority != NOW):
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
        """The next job to run, marked running; None when nothing is due."""
        now = now or time.time()
        with self.lock:
            row = self.connection.execute(
                f"SELECT * FROM job WHERE state = 'queued' AND not_before <= ? ORDER BY {ORDER} LIMIT 1", (now,)).fetchone()
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
