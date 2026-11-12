#!/bin/bash
# Prebuilds the Safari extension's built-in dictionaries on the Mac (the heavy import is more
# than iOS allows an extension on an iPad mini). Source: Dictionaries/Extension (can be a link
# to your own dictionary folder) if it exists, else Dictionaries/*.zip. Output (cached, gitignored):
# Dictionaries/Prebuilt/<name>.hoshidict. Called by the HikuExtension build; safe to run by hand.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Dictionaries"
if [ -d "$SOURCE/Extension" ]; then SOURCE="$SOURCE/Extension"; fi
shopt -s nullglob
ZIPS=("$SOURCE"/*.zip)
if [ ${#ZIPS[@]} -eq 0 ]; then echo "No dictionaries in $SOURCE"; exit 0; fi
# Xcode's build settings (SDKROOT for iOS, etc.) would point SwiftPM at the wrong platform.
env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
    swift run --package-path "$ROOT/Packages/Dictionary" -c release dictionary-prebuild "$ROOT/Dictionaries/Prebuilt" "${ZIPS[@]}"
