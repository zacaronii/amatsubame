# Sourced by upload-dev.sh, release.sh and scripts/tests/homebrew-casks-test.sh: the casks in the
# Homebrew tap (github.com/<owner>/homebrew-amatsubame). Needs fail().

# write_dev_cask <App> <tap folder> <zip> points <app>@dev at this build's zip on the tap's dev
# release, and makes sure the release cask and the dev cask can't both be installed (they're the
# same app). The rest is copied from the release cask, so both describe the app the same way. Needs
# $version, $build and $tap_repo.
write_dev_cask() {
  local app=$1 tap=$2 zip=$3 name cask release sha
  name=$(tr '[:upper:]' '[:lower:]' <<<"$app")
  release="$tap/Casks/$name.rb"
  cask="$tap/Casks/$name@dev.rb"
  [ -f "$release" ] || fail "$tap_repo has no Casks/$name.rb to copy the dev cask from."
  sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
  {
    echo "cask \"$name@dev\" do"
    echo "  version \"$version,$build\""
    echo "  sha256 \"$sha\""
    echo
    echo "  url \"https://github.com/$tap_repo/releases/download/dev/$app-#{version.csv.first}-#{version.csv.second}.zip\""
    echo "  name \"$app (Dev)\""
    grep -E '^  (desc|homepage) ' "$release"
    echo
    echo "  # Each Dev build replaces the last one: brew upgrade --cask $name@dev."
    echo "  livecheck do"
    echo "    skip \"Dev builds come from scripts/upload-dev.sh\""
    echo "  end"
    echo
    echo "  conflicts_with cask: \"$name\""
    grep -E '^  depends_on ' "$release"
    echo
    echo "  app \"$app.app\""
    echo
    # The zap stanza and its comment, however many lines the list takes, up to the cask's own end.
    awk '/^  # The setup the apps share|^  zap /{on=1} /^end$/{on=0} on' "$release"
    echo "end"
  } >"$cask"
  if ! grep -q "conflicts_with cask: \"$name@dev\"" "$release"; then
    sed -i '' -E "s/^(  depends_on arch: .*)$/  conflicts_with cask: \"$name@dev\"\\
\\1/" "$release"
  fi
}

# check_casks <cask.rb ...> stops before anything is pushed when a cask isn't valid Ruby, or when
# brew style (if Homebrew is installed) finds a problem: a broken cask stops every brew command
# that reads the tap.
check_casks() {
  local cask
  for cask in "$@"; do
    ruby -c "$cask" >/dev/null || fail "$cask isn't valid Ruby (ruby -c); not pushing the tap."
  done
  if command -v brew >/dev/null; then
    brew style "$@" >/dev/null || fail "brew style found problems in: $*; not pushing the tap."
  fi
}
