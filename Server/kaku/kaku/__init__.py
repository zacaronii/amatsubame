"""Kaku (書く): keeps Japanese Audiobookshelf libraries transcribed, and Jellyfin episodes on
request. See docs/kaku.md."""

VERSION = '1.10.0'
# Bumped when the pipeline's output changes, so earlier transcripts are made again.
PIPELINE = 2


def model_key(model):
    """What a transcript is "by": the model and the pipeline version (kept per transcript, so the
    apps can say what made it)."""
    return f'{model}/p{PIPELINE}'


def is_current(saved_key, saved_fingerprint, fingerprint):
    """A saved transcript still serves when its audio is unchanged and it came from this pipeline
    version. Another model doesn't make it stale: changing `KAKU_MODEL` affects new jobs and
    Transcribe Again only, so a library isn't transcribed again for it."""
    return saved_fingerprint == fingerprint and saved_key.endswith(f'/p{PIPELINE}')
