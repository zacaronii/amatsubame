#!/bin/zsh
# The README's media (docs/media/CREDITS.md): for each app, the home with the demo servers' content
# (`readme-1-home`) and the popup open on a word (`readme-2-lookup`), taken by its capture UI test in
# dark mode with a clean status bar and exported from the test result as PNGs. For Miru and Kiku the
# player is also recorded (`<app>-raw.mp4`, plus a screenshot about every half second in
# `<app>-shots`, since the video misses the popup's web view): cut their GIFs with readme-gif.py.
#
#   scripts/readme-screenshots.sh <simulator id> <output folder> [Yomu Miru Kiku Hiku]
#
# Servers, keys and passwords come from the environment at run time, never from this file:
#   Yomu: README_KAVITA_URL, README_KAVITA_KEY (a demo Kavita user's API key),
#         README_OCR_MODELS (a folder with compiled/, docs/yomu.md)
#   Miru: README_JELLYFIN_URL, README_JELLYFIN_USER, README_JELLYFIN_PASSWORD
#   Kiku: README_ABS_URL, README_ABS_KEY (a demo Audiobookshelf user's API key or token)
#   all:  README_DICTIONARY_ZIPS (Jitendex)
#   Hiku: README_HIKU_TAP_AT=x,y (points) where 無 is, when the screen isn't an iPhone 17 Pro
#         (iPhone 17 Pro Max: 111,255). Its built-in dictionaries come from Dictionaries/ (docs/hiku.md).
# Optional: README_DERIVED_DATA (default build.noindex/readme-screenshots).
set -u
sim=${1:?simulator id}; out=${2:?output folder}; shift 2
apps=("$@"); (( $#apps )) || apps=(Yomu Miru Kiku Hiku)
cd "$(dirname "$0")/.."
derived=${README_DERIVED_DATA:-build.noindex/readme-screenshots}
mkdir -p "$out"

xcrun simctl boot "$sim" 2>/dev/null; xcrun simctl bootstatus "$sim" -b >/dev/null
xcrun simctl ui "$sim" appearance dark
xcrun simctl status_bar "$sim" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4

# Signs an app in through DevSetup (docs/shared.md), progress held on the simulator.
devsetup() {
  local bundle=$1; shift
  xcrun simctl uninstall "$sim" "$bundle" 2>/dev/null
  xcrun simctl install "$sim" "$derived/Build/Products/Debug-iphonesimulator/${bundle##*.}.app"
  env SIMCTL_CHILD_DEV_SETUP=1 SIMCTL_CHILD_DEV_HOLD_PROGRESS=1 SIMCTL_CHILD_UITEST_MUTE=1 \
    SIMCTL_CHILD_DEV_IMPORT_DICTIONARIES=${README_DICTIONARY_ZIPS:?} "$@" xcrun simctl launch "$sim" "$bundle" >/dev/null
  local log="$(xcrun simctl get_app_container "$sim" "$bundle" data)/Library/Application Support/dev-setup.log"
  for _ in {1..120}; do grep -q "Z Done$" "$log" 2>/dev/null && break; sleep 2; done
  grep -E "Jellyfin|Audiobookshelf" "$log" | tail -1
  xcrun simctl terminate "$sim" "$bundle"
}

for app in $apps; do
  lower=${(L)app}
  echo "== $app"
  xcodebuild build-for-testing -project Amatsubame.xcodeproj -scheme "$app" -destination "platform=iOS Simulator,id=$sim" \
    -derivedDataPath "$derived" -quiet 2>&1 | grep -E " error:" && exit 1
  unset TEST_RUNNER_UITEST_KAVITA_URL TEST_RUNNER_UITEST_CAPTURE_AT
  case $app in
  Yomu)
    export TEST_RUNNER_UITEST_KAVITA_URL=${README_KAVITA_URL:?} TEST_RUNNER_UITEST_KAVITA_KEY=${README_KAVITA_KEY:?}
    export TEST_RUNNER_UITEST_LIBRARY="サンプル・マンガ" TEST_RUNNER_UITEST_SERIES="Pepper&Carrot"
    export TEST_RUNNER_UITEST_OCR_MODELS=${README_OCR_MODELS:?} TEST_RUNNER_UITEST_DICTIONARY_ZIPS=${README_DICTIONARY_ZIPS:?}
    tests=(-only-testing:YomuUITests/ReaderUITests/testReadmeCapture) ;;
  Miru)
    devsetup com.amatsubame.miru SIMCTL_CHILD_DEV_JELLYFIN_URL=${README_JELLYFIN_URL:?} \
      SIMCTL_CHILD_DEV_JELLYFIN_USER=${README_JELLYFIN_USER:?} SIMCTL_CHILD_DEV_JELLYFIN_PASSWORD=${README_JELLYFIN_PASSWORD:?}
    tests=(-only-testing:MiruUITests/ReadmeCaptureUITests/testReadmeCapture) ;;
  Kiku)
    devsetup com.amatsubame.kiku SIMCTL_CHILD_DEV_ABS_URL=${README_ABS_URL:?} SIMCTL_CHILD_DEV_ABS_KEY=${README_ABS_KEY:?}
    export TEST_RUNNER_UITEST_CAPTURE_FOLDER="$PWD/docs/media/capture/kiku" TEST_RUNNER_UITEST_DICTIONARY_ZIPS=${README_DICTIONARY_ZIPS:?}
    tests=(-only-testing:KikuUITests/ReadmeCaptureUITests/testReadmeHome -only-testing:KikuUITests/ReadmeCaptureUITests/testReadmeCapture) ;;
  Hiku)
    [[ -n ${README_HIKU_TAP_AT:-} ]] && export TEST_RUNNER_UITEST_CAPTURE_AT=$README_HIKU_TAP_AT
    tests=(-only-testing:HikuUITests/ExtensionLookupUITests/testReadmeCapture) ;;
  *) echo "No README screenshots set up for $app" >&2; exit 1 ;;
  esac
  result="$derived/readme-$lower.xcresult"; rm -rf -- "${result:?}"
  recorder= shooter=
  if [[ $app == (Miru|Kiku) ]]; then
    raw="$out/$lower-raw.mp4" shots="$out/$lower-shots"
    rm -rf -- "${shots:?}"; mkdir -p "$shots"; rm -f "$raw"
    xcrun simctl io "$sim" recordVideo --codec=h264 --force "$raw" 2>/dev/null &
    recorder=$!
    ( while kill -0 $recorder 2>/dev/null; do
        xcrun simctl io "$sim" screenshot "$shots/$(date +%s).$(( RANDOM % 100 )).png" >/dev/null 2>&1; sleep 0.3
      done ) &
    shooter=$!
    sleep 2
  fi
  TEST_RUNNER_UITEST_CAPTURE=1 TEST_RUNNER_UITEST_MUTE=1 xcodebuild test-without-building -project Amatsubame.xcodeproj -scheme "$app" \
    -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$derived" -resultBundlePath "$result" $tests 2>&1 \
    | grep -E "Test Case .*(passed|failed)|error:" | tail -4
  if [[ -n $recorder ]]; then kill -INT $recorder; wait $recorder 2>/dev/null; wait $shooter 2>/dev/null; fi
  attachments=$(mktemp -d)
  xcrun xcresulttool export attachments --path "$result" --output-path "$attachments" >/dev/null
  python3 -I - "$attachments" "$out" "$lower" <<'PY'
import json, shutil, sys
from pathlib import Path
folder, out, app = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
for test in json.loads((folder / "manifest.json").read_text()):
    for item in test.get("attachments", []):
        name = item.get("suggestedHumanReadableName", "")
        for shot in ("readme-1-home", "readme-2-lookup"):
            if name.startswith(shot):
                target = out / f"{app}-{shot.removeprefix('readme-')}.png"
                shutil.copy(folder / item["exportedFileName"], target)
                print(target)
PY
  rm -rf -- "${attachments:?}"
done
