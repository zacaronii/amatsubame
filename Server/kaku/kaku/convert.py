"""Converts litagin/anime-whisper (MIT) for faster-whisper, once, into the models folder:
CTranslate2 float16, a tokenizer.json, and alignment heads its 2-layer decoder has.

It needs transformers, torch and ctranslate2, which the Kaku image doesn't carry, so it runs in a
one-off container (`./convert-model.sh`, docs/kaku.md ▸ Model). Kaku then loads
<models>/anime-whisper-ct2 and checks it (`pipeline.check_converted`).
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess

from .pipeline import ANIME_WHISPER_FOLDER, ANIME_WHISPER_HEADS, check_converted

REPOSITORY = 'litagin/anime-whisper'
# The revision compared against large-v3 (2026-11-24).
REVISION = '22e2008a8182b357da3922a6308d095008f72973'


def fix_alignment_heads(folder):
    """The converted config carries large-v3's alignment heads (layers up to 31); with a 2-layer
    decoder, word timestamps then crash. Use every head of the last decoder layer."""
    path = os.path.join(folder, 'config.json')
    with open(path, encoding='utf-8') as file:
        config = json.load(file)
    config['alignment_heads'] = ANIME_WHISPER_HEADS
    with open(path, 'w', encoding='utf-8') as file:
        json.dump(config, file, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--models', default=os.environ.get('KAKU_MODELS', '/models'))
    parser.add_argument('--force', action='store_true', help='convert again over a good conversion')
    arguments = parser.parse_args()
    target = os.path.join(arguments.models, ANIME_WHISPER_FOLDER)
    if not arguments.force:
        try:
            check_converted(target)
            print(f'{target} is already converted')
            return
        except RuntimeError:
            pass
    work = target + '.tmp'
    shutil.rmtree(work, ignore_errors=True)
    subprocess.run(['ct2-transformers-converter', '--model', REPOSITORY, '--revision', REVISION,
                    '--output_dir', work, '--quantization', 'float16',
                    '--copy_files', 'preprocessor_config.json', 'normalizer.json'], check=True)
    # The repository has no tokenizer.json (faster-whisper would fall back to another model's).
    from transformers import AutoTokenizer
    AutoTokenizer.from_pretrained(REPOSITORY, revision=REVISION).backend_tokenizer.save(os.path.join(work, 'tokenizer.json'))
    fix_alignment_heads(work)
    check_converted(work)
    shutil.rmtree(target, ignore_errors=True)
    os.replace(work, target)
    print(f'converted {REPOSITORY}@{REVISION[:7]} into {target}')


if __name__ == '__main__':
    main()
