#!/bin/sh
# Fetches the pinned nemu OCR Core ML models (Apache-2.0) into Models/ for tests.
# The app downloads the same files at runtime (Settings → OCR); keep REVISION in
# sync with OCRModelStore.revision.
set -eu
REVISION=691285cc539f4662f785540efcc9a62d51a1095c
BASE="https://huggingface.co/nemu-pm/nemu-ocr-coreml/resolve/$REVISION"
DEST="${1:-$(dirname "$0")/../Models}"
FILES="vocab.txt
ogkalu-ctbd-v4s-fp16.mlpackage/Manifest.json
ogkalu-ctbd-v4s-fp16.mlpackage/Data/com.apple.CoreML/model.mlmodel
ogkalu-ctbd-v4s-fp16.mlpackage/Data/com.apple.CoreML/weights/weight.bin
mangaocr-encoder-int8.mlpackage/Manifest.json
mangaocr-encoder-int8.mlpackage/Data/com.apple.CoreML/model.mlmodel
mangaocr-encoder-int8.mlpackage/Data/com.apple.CoreML/weights/weight.bin
mangaocr-decoder-int8.mlpackage/Manifest.json
mangaocr-decoder-int8.mlpackage/Data/com.apple.CoreML/model.mlmodel
mangaocr-decoder-int8.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
echo "$FILES" | while read -r file; do
  mkdir -p "$DEST/$(dirname "$file")"
  if [ ! -s "$DEST/$file" ]; then
    echo "Fetching $file"
    curl -sSfL -o "$DEST/$file" "$BASE/$file"
  fi
done
echo "Models in $DEST"
