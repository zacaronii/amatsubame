"""Kaku (書く): keeps Japanese Audiobookshelf libraries transcribed, and Jellyfin episodes on
request. See docs/kaku.md."""

VERSION = '1.4.2'
# Bumped when the pipeline's output changes, so earlier transcripts are made again.
PIPELINE = 2


def model_key(model):
    """What a transcript is "by": the model and the pipeline version."""
    return f'{model}/p{PIPELINE}'
