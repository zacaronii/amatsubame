#!/bin/sh
# Makes the local media Miru's player UI tests expect, with ffmpeg (brew install ffmpeg), and
# prints the variables to pass them to `xcodebuild test`:
#
#   scripts/make-test-media.sh [folder]      (default: build.noindex/test-media)
#
# - video.mp4: 60 s of H.264 (640×360, 24 fps) with a silent AAC track. The tests' numbers come
#   from its length: a scrub across half the width is ~7.5 s, the Up Next card shows from 41 s.
#   It also has the audio track the background-audio test needs (silent, so runs make no sound).
# - chapters.mp4: the same 60 s with chapters at 0, 15 and 40 s.
# - english.srt: an English line every 3 s across the 60 s, for the English Subtitles test.
set -eu
command -v ffmpeg >/dev/null || { echo "error: ffmpeg is missing (brew install ffmpeg)." >&2; exit 1; }
DEST="${1:-$(dirname "$0")/../build.noindex/test-media}"
mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd)
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT

picture="testsrc2=size=640x360:rate=24"
ffmpeg -loglevel error -y -f lavfi -i "$picture" -f lavfi -i anullsrc=r=48000:cl=stereo -t 60 \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$DEST/video.mp4"

cat >"$work/chapters.txt" <<EOF
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=15000
title=Opening
[CHAPTER]
TIMEBASE=1/1000
START=15000
END=40000
title=Part A
[CHAPTER]
TIMEBASE=1/1000
START=40000
END=60000
title=Part B
EOF
ffmpeg -loglevel error -y -i "$DEST/video.mp4" -i "$work/chapters.txt" -map 0 -map_chapters 1 -c copy "$DEST/chapters.mp4"

: >"$DEST/english.srt"
line=1
while [ $line -le 20 ]; do
  start=$(( (line - 1) * 3 ))
  end=$(( start + 3 )); [ $end -gt 59 ] && end=59
  printf '%d\n00:00:%02d,000 --> 00:00:%02d,000\nEnglish line %d\n\n' $line $start $end $line >>"$DEST/english.srt"
  line=$(( line + 1 ))
done

echo "Test media in $DEST. Run Miru's UI tests with:"
echo "  TEST_RUNNER_UITEST_PLAYER_VIDEO=$DEST/video.mp4 \\"
echo "  TEST_RUNNER_UITEST_PLAYER_AUDIO_VIDEO=$DEST/video.mp4 \\"
echo "  TEST_RUNNER_UITEST_PLAYER_CHAPTERS_VIDEO=$DEST/chapters.mp4 \\"
echo "  TEST_RUNNER_UITEST_PLAYER_ENGLISH_FILE=$DEST/english.srt \\"
echo "  xcodebuild test -scheme Miru -destination 'platform=iOS Simulator,name=<an iPhone>'"
