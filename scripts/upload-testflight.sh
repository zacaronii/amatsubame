#!/bin/bash
# Archives the apps for iOS and macOS and uploads them to App Store Connect (TestFlight).
#
#   scripts/upload-testflight.sh [--no-upload] [App ...]
#
# Apps default to Yomu Miru Kiku Hiku. Each is archived and exported (signed for the App Store) into
# build.noindex/testflight/<build>/, then uploaded; --no-upload stops after the export.
#
# Needs, besides a clean checkout:
# - Config/Signing.local.xcconfig with DEVELOPMENT_TEAM (a paid team) and AMATSUBAME_APP_GROUP = YES.
# - That team's Apple ID signed in to Xcode (Settings ▸ Accounts): signing goes through it, since an
#   App Manager API key can't manage certificates and profiles.
# - For uploading, an App Store Connect API key (App Manager) in the login keychain, the .p8 file base64-encoded:
#     security add-generic-password -s amatsubame.asc -a <Key ID> -j <Issuer ID> -w "$(base64 -i AuthKey_<Key ID>.p8)"
#
# Each run gets a new build number from the time (YYYYMMDD.HHMM, UTC), so nothing in the repo changes;
# the version shown in TestFlight is MARKETING_VERSION from project.yml.
set -euo pipefail
cd "$(dirname "$0")/.."

upload=1
apps=()
for arg in "$@"; do
  case "$arg" in
    --no-upload) upload=0 ;;
    Yomu|Miru|Kiku|Hiku) apps+=("$arg") ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[ ${#apps[@]} -gt 0 ] || apps=(Yomu Miru Kiku Hiku)

fail() { echo "error: $*" >&2; exit 1; }

# Only committed work, and never local-only commits (the demo fill-in).
[ -z "$(git status --porcelain)" ] || fail "the working tree has changes; commit or stash them first."
if git log --format=%B "@{upstream}..HEAD" 2>/dev/null | grep -q "LOCAL ONLY" \
   || git log --format=%B "origin/main..HEAD" | grep -q "LOCAL ONLY"; then
  fail "this branch has LOCAL ONLY commits."
fi

local_config=Config/Signing.local.xcconfig
[ -f "$local_config" ] || fail "$local_config is missing."
team=$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]+).*/\1/p' "$local_config" | tail -1)
[ -n "$team" ] || fail "no DEVELOPMENT_TEAM in $local_config."
grep -qE '^[[:space:]]*AMATSUBAME_APP_GROUP[[:space:]]*=[[:space:]]*YES' "$local_config" \
  || fail "set AMATSUBAME_APP_GROUP = YES in $local_config."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [ $upload = 1 ]; then
  # The API key, from the keychain into a file only this run can read.
  item=$(security find-generic-password -s amatsubame.asc 2>/dev/null) \
    || fail "no App Store Connect key in the keychain (service amatsubame.asc); see the top of this script."
  key_id=$(sed -nE 's/^[[:space:]]*"acct"<blob>="(.*)"$/\1/p' <<<"$item")
  issuer=$(sed -nE 's/^[[:space:]]*"icmt"<blob>="(.*)"$/\1/p' <<<"$item")
  [ -n "$key_id" ] && [ -n "$issuer" ] || fail "the keychain item needs the Key ID as its account and the Issuer ID as its comment."
  key_file="$work/AuthKey_$key_id.p8"
  (umask 077; security find-generic-password -s amatsubame.asc -w | base64 -D > "$key_file")
  grep -q "BEGIN PRIVATE KEY" "$key_file" || fail "the keychain item doesn't hold a base64-encoded .p8 key."
fi

build=$(date -u +%Y%m%d.%H%M)
out="build.noindex/testflight/$build"
mkdir -p "$out"
# Internal testing only for now: such builds can't go to external testers or the App Store.
cat > "$work/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>export</string>
	<key>teamID</key><string>$team</string>
	<key>signingStyle</key><string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>uploadSymbols</key><true/>
	<key>testFlightInternalTestingOnly</key><true/>
</dict>
</plist>
EOF

xcodegen >/dev/null
echo "Build $build of: ${apps[*]} ($([ $upload = 1 ] && echo uploading || echo "not uploading"))"
for app in "${apps[@]}"; do
  for platform in iOS macOS; do
    archive="$out/$app-$platform.xcarchive"
    log="$out/$app-$platform.log"
    # The Mac builds are Apple silicon only (the OCR code's Float16 doesn't exist on Intel).
    extra=()
    [ "$platform" = macOS ] && extra=(ARCHS=arm64)
    echo "• $app ($platform): archiving"
    xcodebuild archive -project Amatsubame.xcodeproj -scheme "$app" -configuration Release \
      -destination "generic/platform=$platform" -archivePath "$archive" \
      -derivedDataPath "build.noindex/testflight/derived-$platform" \
      CURRENT_PROJECT_VERSION="$build" AMATSUBAME_APP_GROUP=YES "${extra[@]}" -allowProvisioningUpdates >"$log" 2>&1 \
      || fail "archiving $app for $platform failed; see $log"
    echo "• $app ($platform): exporting"
    xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$work/ExportOptions.plist" \
      -exportPath "$out/$app-$platform" -allowProvisioningUpdates >>"$log" 2>&1 \
      || fail "exporting $app for $platform failed; see $log"
    [ $upload = 1 ] || continue
    package=$(ls "$out/$app-$platform/"*.ipa "$out/$app-$platform/"*.pkg 2>/dev/null | head -1)
    [ -n "$package" ] || fail "no .ipa or .pkg for $app ($platform) in $out/$app-$platform"
    echo "• $app ($platform): uploading"
    xcrun altool --upload-package "$package" --api-key "$key_id" --api-issuer "$issuer" \
      --p8-file-path "$key_file" >>"$log" 2>&1 \
      || fail "uploading $app for $platform failed; see $log"
  done
done
echo "Done. Archives and logs are in $out."
