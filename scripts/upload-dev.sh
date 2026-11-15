#!/bin/bash
# Archives the four apps for iOS and macOS from the current commit and uploads them to App Store
# Connect, where the TestFlight "Dev" group gets them. Releases reuse these builds (scripts/release.sh).
# Dev builds come from the dev branch (README ▸ Branches); a build from anywhere else says so.
#
#   scripts/upload-dev.sh [--no-upload] [App ...]
#
# Apps default to Yomu Miru Kiku Hiku. Each is archived and exported (signed for the App Store) into
# build.noindex/testflight/<build>/, then uploaded; --no-upload stops after the export.
#
# All the apps get one build number, the upload time (YYYYMMDDHHMM, UTC): it only ever goes up, and
# Mac builds must always be higher than any uploaded before. Once the first upload has gone through,
# the tag build-<number> is pushed on the commit, so a release can find what a build came from.
#
# Needs, besides a clean checkout:
# - Config/Signing.local.xcconfig with DEVELOPMENT_TEAM (a paid team) and AMATSUBAME_APP_GROUP = YES.
# - That team's Apple ID signed in to Xcode (Settings ▸ Accounts): signing goes through it, since an
#   App Manager API key can't manage certificates and profiles.
# - For uploading, an App Store Connect API key (App Manager) in the login keychain (scripts/asc-key.sh).
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
git fetch -q origin main dev
if git log --format=%B "origin/dev..HEAD" | grep -q "LOCAL ONLY"; then
  fail "this branch has LOCAL ONLY commits."
fi
git merge-base --is-ancestor HEAD origin/dev || git merge-base --is-ancestor HEAD origin/main \
  || echo "Note: $(git rev-parse --short HEAD) isn't on dev yet; releases only take builds that reach main."

# Hiku's Safari extension has its own copy of the version.
version=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9.]+)"?.*/\1/p' project.yml | head -1)
manifest_version=$(sed -nE 's/^[[:space:]]*"version":[[:space:]]*"([0-9.]+)".*/\1/p' HikuExtension/Resources/manifest.json)
[ "$version" = "$manifest_version" ] \
  || fail "project.yml says $version but HikuExtension/Resources/manifest.json says $manifest_version."

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
  . scripts/asc-key.sh
  load_asc_key "$work"
fi

build=$(date -u +%Y%m%d%H%M)
commit=$(git rev-parse HEAD)
out="build.noindex/testflight/$build"
mkdir -p "$out"
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
</dict>
</plist>
EOF

# The build's tag, pushed once something with this number is on App Store Connect.
tagged=0
tag_build() {
  [ $tagged = 0 ] || return 0
  git tag "build-$build" "$commit"
  git push -q origin "build-$build"
  tagged=1
}

xcodegen >/dev/null
echo "Build $build (version $version, commit $(git rev-parse --short HEAD)) of: ${apps[*]} ($([ $upload = 1 ] && echo uploading || echo "not uploading"))"
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
      CURRENT_PROJECT_VERSION="$build" AMATSUBAME_APP_GROUP=YES ${extra[@]+"${extra[@]}"} -allowProvisioningUpdates >"$log" 2>&1 \
      || fail "archiving $app for $platform failed; see $log"
    echo "• $app ($platform): exporting"
    xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$work/ExportOptions.plist" \
      -exportPath "$out/$app-$platform" -allowProvisioningUpdates >>"$log" 2>&1 \
      || fail "exporting $app for $platform failed; see $log"
    [ $upload = 1 ] || continue
    package=$(find "$out/$app-$platform" -maxdepth 1 \( -name "*.ipa" -o -name "*.pkg" \) | head -1)
    [ -n "$package" ] || fail "no .ipa or .pkg for $app ($platform) in $out/$app-$platform"
    echo "• $app ($platform): uploading"
    xcrun altool --upload-package "$package" --api-key "$key_id" --api-issuer "$issuer" \
      --p8-file-path "$key_file" >>"$log" 2>&1 \
      || fail "uploading $app for $platform failed; see $log$([ $tagged = 1 ] && echo " (build-$build is tagged: the uploads before this one went through)")"
    tag_build
  done
done
if [ $upload = 1 ]; then
  echo "Done: build $build is on its way to the Dev group (tag build-$build). Archives and logs are in $out."
else
  echo "Done. Archives and logs are in $out."
fi
