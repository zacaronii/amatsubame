#!/bin/sh
# Checks that every app and extension in a build has a privacy manifest (PrivacyInfo.xcprivacy):
# App Store Connect expects one in each bundle that uses a required-reason API.
#   scripts/check-privacy-manifests.sh <.xcarchive, .app or build folder> …
# Frameworks are skipped (packages bring their own). Exits 1 if any bundle has none.
set -eu
[ $# -gt 0 ] || { echo "usage: $0 <.xcarchive | .app | folder> …" >&2; exit 2; }
bundles=$(find "$@" \( -name '*.app' -o -name '*.appex' \) -not -path '*.framework/*' | sort -u)
missing=0
IFS='
'
for bundle in $bundles; do
  # iOS and watchOS bundles are flat; Mac bundles keep resources in Contents/Resources.
  if [ -f "$bundle/PrivacyInfo.xcprivacy" ] || [ -f "$bundle/Contents/Resources/PrivacyInfo.xcprivacy" ]; then
    echo "ok       $bundle"
  else
    echo "MISSING  $bundle"
    missing=1
  fi
done
exit "$missing"
