#!/bin/sh
# Converts anime-whisper (Kaku's model) into ./models once: CTranslate2 float16 with a
# tokenizer.json and the alignment heads its 2-layer decoder has (kaku/convert.py). It runs in a
# throwaway CPU container, since the Kaku image doesn't carry transformers and torch; a few
# minutes, about 5 GB of downloads (kept out of the models folder). Then restart Kaku.
#   ./convert-model.sh [models folder, default ./models] [--force]
set -e
cd "$(dirname "$0")"
models=$(cd "${1:-./models}" && pwd)
[ "$1" ] && shift
docker run --rm -v "$models:/models" -v "$PWD/kaku:/app/kaku:ro" -w /app python:3.12-slim sh -c '
  pip install --quiet --no-cache-dir "transformers>=4.56,<5" "ctranslate2>=4.6,<5" &&
  pip install --quiet --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu &&
  HF_HOME=/tmp/hf python3 -m kaku.convert --models /models '"$*"
