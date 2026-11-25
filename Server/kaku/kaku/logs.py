"""Kaku's log for the web page (1.9): the last lines in memory (the page's log tail), and the lines
a job wrote while it ran, kept with a failure for 14 days. Keys are taken out of both: an ffmpeg
command or a request's error can carry one."""
from __future__ import annotations

import collections
import logging
import threading
import urllib.parse

FORMAT = '%(asctime)s %(name)s %(levelname)s %(message)s'
# The page's log tail.
TAIL_LINES = 500
# A failed job keeps its last lines and traceback.
JOB_LINES = 50


class Redactor:
    """Replaces each secret (the API token, server keys, the UI secret) with •••, also as a URL
    carries it (percent-encoded, or with + for spaces): a request's error can print its URL."""

    def __init__(self, secrets=()):
        forms = []
        for secret in secrets:
            if not secret or len(secret) < 4:
                continue
            for form in (secret, urllib.parse.quote(secret, safe=''), urllib.parse.quote(secret), urllib.parse.quote_plus(secret)):
                if form not in forms:
                    forms.append(form)
        # Longest first, so a secret inside another's encoded form is still replaced whole.
        self.secrets = sorted(forms, key=len, reverse=True)

    def __call__(self, text):
        for secret in self.secrets:
            text = text.replace(secret, '•••')
        return text


class RingHandler(logging.Handler):
    """The last `TAIL_LINES` lines from every logger, formatted and with keys taken out."""

    def __init__(self, capacity=TAIL_LINES):
        super().__init__()
        self.lines = collections.deque(maxlen=capacity)
        self.redact = Redactor()
        self.setFormatter(logging.Formatter(FORMAT))

    def emit(self, record):
        try:
            self.lines.append(self.redact(self.format(record)))
        except Exception:
            self.handleError(record)


class JobLog(logging.Handler):
    """While a job runs: the lines the worker's thread logs (other threads' lines aren't the job's)."""

    def __init__(self, redact):
        super().__init__()
        self.thread = threading.get_ident()
        self.lines = collections.deque(maxlen=JOB_LINES)
        self.redact = redact
        self.setFormatter(logging.Formatter(FORMAT))

    def emit(self, record):
        if record.thread == self.thread:
            try:
                self.lines.append(self.redact(self.format(record)))
            except Exception:
                self.handleError(record)

    def __enter__(self):
        logging.getLogger().addHandler(self)
        return self

    def __exit__(self, *exc):
        logging.getLogger().removeHandler(self)

    def text(self):
        return '\n'.join(self.lines)


RING = RingHandler()


def install(secrets):
    """Kaku's log goes to the ring too (once), with these secrets taken out."""
    RING.redact = Redactor(secrets)
    root = logging.getLogger()
    if RING not in root.handlers:
        root.addHandler(RING)
