#!/bin/zsh
# Records one app's README capture test in a simulator (docs/media/CREDITS.md): screen video plus
# a screenshot about every half second (the video misses the lookup popup's web view). Cut the GIF
# from them with scripts/readme-gif.py.
#
#   scripts/record-readme-gif.sh <Yomu|Miru> <simulator id> <output folder>
#
# Servers, keys and passwords come from the environment at run time, never from this file:
#   Yomu: README_KAVITA_URL, README_KAVITA_KEY (a demo Kavita user's API key),
#         README_OCR_MODELS (a folder with compiled/, docs/yomu.md), README_DICTIONARY_ZIPS
#   Miru: README_JELLYFIN_URL, README_JELLYFIN_USER, README_JELLYFIN_PASSWORD, README_DICTIONARY_ZIPS
# Optional: README_DERIVED_DATA (default build.noindex/readme-gif).
set -u
app=${1:?app}; sim=${2:?simulator id}; out=${3:?output folder}
cd "$(dirname "$0")/.."
derived=${README_DERIVED_DATA:-build.noindex/readme-gif}
lower=${(L)app}
mkdir -p "$out"

xcrun simctl boot "$sim" 2>/dev/null; xcrun simctl bootstatus "$sim" -b >/dev/null
xcrun simctl status_bar "$sim" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcodebuild build-for-testing -project Amatsubame.xcodeproj -scheme "$app" -destination "platform=iOS Simulator,id=$sim" \
  -derivedDataPath "$derived" -quiet 2>&1 | grep -E " error:" && exit 1

case $app in
Yomu)
  export TEST_RUNNER_UITEST_KAVITA_URL=${README_KAVITA_URL:?} TEST_RUNNER_UITEST_KAVITA_KEY=${README_KAVITA_KEY:?}
  export TEST_RUNNER_UITEST_LIBRARY="サンプル・マンガ" TEST_RUNNER_UITEST_SERIES="Pepper&Carrot"
  export TEST_RUNNER_UITEST_OCR_MODELS=${README_OCR_MODELS:?} TEST_RUNNER_UITEST_DICTIONARY_ZIPS=${README_DICTIONARY_ZIPS:?}
  only=YomuUITests/ReaderUITests/testReadmeCapture ;;
Miru)
  # Signed in through DevSetup (docs/shared.md), progress held on the simulator.
  xcrun simctl uninstall "$sim" com.amatsubame.miru 2>/dev/null
  xcrun simctl install "$sim" "$derived/Build/Products/Debug-iphonesimulator/Miru.app"
  SIMCTL_CHILD_DEV_SETUP=1 SIMCTL_CHILD_DEV_HOLD_PROGRESS=1 SIMCTL_CHILD_UITEST_MUTE=1 \
  SIMCTL_CHILD_DEV_JELLYFIN_URL=${README_JELLYFIN_URL:?} SIMCTL_CHILD_DEV_JELLYFIN_USER=${README_JELLYFIN_USER:?} \
  SIMCTL_CHILD_DEV_JELLYFIN_PASSWORD=${README_JELLYFIN_PASSWORD:?} SIMCTL_CHILD_DEV_IMPORT_DICTIONARIES=${README_DICTIONARY_ZIPS:?} \
    xcrun simctl launch "$sim" com.amatsubame.miru >/dev/null
  log="$(xcrun simctl get_app_container "$sim" com.amatsubame.miru data)/Library/Application Support/dev-setup.log"
  for _ in {1..120}; do grep -q "Z Done$" "$log" 2>/dev/null && break; sleep 2; done
  grep -E "Jellyfin|Dictionary" "$log" | tail -2
  xcrun simctl terminate "$sim" com.amatsubame.miru
  only=MiruUITests/ReadmeCaptureUITests/testReadmeCapture ;;
*) echo "No README capture set up for $app" >&2; exit 1 ;;
esac

raw="$out/$lower-raw.mp4" shots="$out/$lower-shots"
rm -rf -- "${shots:?}"; mkdir -p "$shots"; rm -f "$raw"
xcrun simctl io "$sim" recordVideo --codec=h264 --force "$raw" 2>/dev/null &
recorder=$!
( while kill -0 $recorder 2>/dev/null; do
    xcrun simctl io "$sim" screenshot "$shots/$(date +%s).$(( RANDOM % 100 )).png" >/dev/null 2>&1; sleep 0.3
  done ) &
shooter=$!
sleep 2
TEST_RUNNER_UITEST_CAPTURE=1 TEST_RUNNER_UITEST_MUTE=1 xcodebuild test-without-building -project Amatsubame.xcodeproj -scheme "$app" \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$derived" -only-testing:$only 2>&1 \
  | grep -E "Test Case|error:|skipped|\*\* TEST" | tail -4
kill -INT $recorder; wait $recorder 2>/dev/null; wait $shooter 2>/dev/null
echo "$raw, $(ls "$shots" | wc -l | tr -d ' ') screenshots in $shots"
