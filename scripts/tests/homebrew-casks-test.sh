#!/bin/bash
# Tests scripts/homebrew-casks.sh offline: write_dev_cask copies a one-line and a multi-line zap whole
# and keeps a pinned backup cask in the conflicts, and check_casks stops on a cask Ruby can't read.
#
#   scripts/tests/homebrew-casks-test.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "error: $*" >&2; exit 1; }
. scripts/homebrew-casks.sh

work=$(mktemp -d "${TMPDIR:-/tmp}/homebrew-casks-test.XXXXXX")
trap 'rm -rf "${work:?}"' EXIT
tap="$work/tap"
mkdir -p "$tap/Casks"
version=1.2.3 build=202601010000 tap_repo=example/homebrew-amatsubame
printf 'zip' >"$work/App.zip"
sha=$(shasum -a 256 "$work/App.zip" | cut -d' ' -f1)

release_cask() { # <name> <App> <zap lines>
  cat <<EOF
cask "$1" do
  version "1.2.0"
  sha256 "0000"

  url "https://example.com/$1.zip"
  name "$2"
  desc "Something"
  homepage "https://amatsubame.com/$1/"

  livecheck do
    url :url
    strategy :github_releases
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "$2.app"

  # The setup the apps share (group.com.amatsubame) stays: the other Amatsubame apps use it.
$3
end
EOF
}
one='  zap trash: "~/Library/Containers/com.amatsubame.one"'
many='  zap trash: [
    "~/Library/Containers/com.amatsubame.many",
    "~/Library/Containers/com.amatsubame.many.extension",
  ]'
release_cask one One "$one" >"$tap/Casks/one.rb"
release_cask many Many "$many" >"$tap/Casks/many.rb"

for app in One Many; do
  name=$(tr '[:upper:]' '[:lower:]' <<<"$app")
  write_dev_cask "$app" "$tap" "$work/App.zip"
  zap=$one; [ $name = many ] && zap=$many
  expected=$(cat <<EOF
cask "$name@dev" do
  version "1.2.3,202601010000"
  sha256 "$sha"

  url "https://github.com/example/homebrew-amatsubame/releases/download/dev/$app-#{version.csv.first}-#{version.csv.second}.zip"
  name "$app (Dev)"
  desc "Something"
  homepage "https://amatsubame.com/$name/"

  # Each Dev build replaces the last one: brew upgrade --cask $name@dev.
  livecheck do
    skip "Dev builds come from scripts/upload-dev.sh"
  end

  conflicts_with cask: "$name"
  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "$app.app"

  # The setup the apps share (group.com.amatsubame) stays: the other Amatsubame apps use it.
$zap
end
EOF
)
  diff <(echo "$expected") "$tap/Casks/$name@dev.rb" || fail "$name@dev.rb isn't the expected cask"
  grep -q "conflicts_with cask: \"$name@dev\"" "$tap/Casks/$name.rb" || fail "$name.rb doesn't conflict with $name@dev"
  # A second build doesn't add the conflict again.
  write_dev_cask "$app" "$tap" "$work/App.zip"
  [ "$(grep -c "conflicts_with cask: \"$name@dev\"" "$tap/Casks/$name.rb")" = 1 ] || fail "$name.rb got the conflict twice"
done
check_casks "$tap"/Casks/*.rb

# A pinned backup (like miru@mpv) joins both casks' conflicts, as one list that a later build keeps.
cat >"$tap/Casks/one@mpv.rb" <<'EOF'
cask "one@mpv" do
  version "1.1.0,202501010000"
  sha256 "0000"

  url "https://example.com/one-mpv.zip"
  name "One (mpv)"
  desc "Something"
  homepage "https://amatsubame.com/one/"

  livecheck do
    skip "Pinned backup"
  end

  conflicts_with cask: ["one", "one@dev"]
  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "One.app"
end
EOF
for build in 1 2; do
  write_dev_cask One "$tap" "$work/App.zip"
  [ "$(grep -c '^  conflicts_with ' "$tap/Casks/one@dev.rb")" = 1 ] \
    && grep -qx '  conflicts_with cask: \["one", "one@mpv"\]' "$tap/Casks/one@dev.rb" \
    || fail "one@dev.rb doesn't conflict with exactly one and one@mpv (build $build)"
  [ "$(grep -c '^  conflicts_with ' "$tap/Casks/one.rb")" = 1 ] \
    && grep -qx '  conflicts_with cask: \["one@dev", "one@mpv"\]' "$tap/Casks/one.rb" \
    || fail "one.rb doesn't conflict with exactly one@dev and one@mpv (build $build)"
done
grep -qx '  conflicts_with cask: "many@dev"' "$tap/Casks/many.rb" || fail "many.rb picked up one's backup"
check_casks "$tap"/Casks/*.rb

# The cask the old grep wrote: the list's first line only.
release_cask broken Broken '  zap trash: [' >"$tap/Casks/broken.rb"
if (check_casks "$tap/Casks/broken.rb") 2>/dev/null; then fail "check_casks passed a cask with an unclosed list"; fi

echo "homebrew-casks: all passed"
