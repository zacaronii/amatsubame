"""Splits the saved transcripts into lines again from their stored words, after the splitting
rules change (no model, no GPU): `python3 -m kaku.resplit [--dry-run]` inside the container.
Changed transcripts get `source.resplit` (the Kaku version and when), which the apps don't need:
Kiku refreshes a saved transcript whose lines differ."""
from __future__ import annotations

import argparse
import datetime
import glob
import json
import os

from . import VERSION
from .config import Config
from .transcript import resplit, write


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true', help='count the changes, write nothing')
    arguments = parser.parse_args()
    folder = os.path.join(Config.from_env().data_dir, 'transcripts')
    changed = 0
    paths = sorted(glob.glob(os.path.join(folder, '*', '*.json')))
    for path in paths:
        with open(path, encoding='utf-8') as file:
            transcript = json.load(file)
        updated = resplit(transcript)
        if updated is None:
            continue
        changed += 1
        if arguments.dry_run:
            continue
        updated['source'] = dict(updated['source'], resplit={
            'kaku': VERSION, 'at': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')})
        write(os.path.dirname(path), os.path.splitext(os.path.basename(path))[0], updated)
    print(f'{changed} of {len(paths)} transcripts {"would change" if arguments.dry_run else "split again"}')


if __name__ == '__main__':
    main()
