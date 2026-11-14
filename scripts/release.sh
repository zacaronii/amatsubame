#!/bin/bash
# Releases a TestFlight build that's already in the Dev group: checks it, tags it v<version>,
# makes the GitHub pre-release and opens the PR that moves main to the next version. Nothing is
# rebuilt or uploaded; the build goes to the main tester group by hand in App Store Connect.
#
#   scripts/release.sh <build number>     e.g. scripts/release.sh 202611201530
#   scripts/release.sh --check-only <build number>   (the checks only)
#
# The checklist (README ▸ Releasing): on the build's commit, in a separate worktree,
# - all four apps build for iOS and macOS,
# - the package tests, the apps' unit tests (on an iPhone simulator; RELEASE_SIMULATOR=<udid> picks
#   one, never the Amatsubame ones) and Kaku's tests pass,
# - no open issue has the "blocks release" label,
# - the version fits what's in it: a release with features (PRs labelled idea or enhancement) moves
#   the middle number (0.3.0), a fix-only one the last (0.2.1),
# then you confirm the hand checks (every PR since the last release tried, a day or two in Dev).
# Logs go to build.noindex/release/<version>/.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)

check_only=0
[ "${1:-}" = "--check-only" ] && { check_only=1; shift; }
[ $# = 1 ] || { echo "usage: scripts/release.sh [--check-only] <build number>" >&2; exit 2; }
build=$1
# App Store Connect drops leading zeros after a dot (the first builds were 20261114.0221).
if [[ "$build" == *.* ]]; then build="${build%%.*}.$(printf %04d "$((10#${build#*.}))")"; fi

fail() { echo "error: $*" >&2; exit 1; }
step() { echo "• $*"; }

git fetch -q --tags origin main
commit=$(git rev-parse -q --verify "refs/tags/build-$build^{commit}") \
  || fail "no tag build-$build: was that build uploaded with scripts/upload-dev.sh?"
git merge-base --is-ancestor "$commit" origin/main \
  || fail "build $build (${commit:0:7}) isn't on main. Releases come from main: merge first and upload a new build."
version=$(git show "$commit:project.yml" | sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9.]+)"?.*/\1/p' | head -1)
[ -n "$version" ] || fail "no MARKETING_VERSION in project.yml at ${commit:0:7}."
if [ $check_only = 0 ]; then
  git rev-parse -q --verify "refs/tags/v$version" >/dev/null && fail "v$version is already tagged."
  git ls-remote --exit-code --tags origin "refs/tags/v$version" >/dev/null && fail "v$version is already on GitHub."
fi
echo "Build $build is commit ${commit:0:7}, version $version."

logs="build.noindex/release/$version"
mkdir -p "$logs"
failures=()

# The pull requests since the last release, with their labels.
previous=$(git describe --tags --match 'v*' --abbrev=0 "$commit" 2>/dev/null || true)
prs=$(git log --first-parent --merges --format=%s ${previous:+"$previous.."}"$commit" | sed -nE 's/^Merge pull request #([0-9]+).*/\1/p')
features=()
for pr in $prs; do
  labels=$(gh pr view "$pr" --json labels -q '.labels[].name')
  grep -qxE 'idea|enhancement' <<<"$labels" && features+=("#$pr")
done

step "Version"
IFS=. read -r major minor patch <<<"$version"
if [ ${#features[@]} -gt 0 ] && [ "${patch:-0}" != 0 ]; then
  echo "  $version is a fix-only number, but ${features[*]} added features: those release as $major.$((minor + 1)).0."
  echo "  Set MARKETING_VERSION in project.yml and HikuExtension/Resources/manifest.json on main, then upload again."
  failures+=("version $version for a release with features")
else
  echo "  ok ($([ ${#features[@]} -gt 0 ] && echo "features: ${features[*]}" || echo "fixes only"))"
fi

step "Issues labelled \"blocks release\""
blockers=$(gh issue list --state open --label "blocks release" --json number,title -q '.[] | "  #\(.number) \(.title)"')
[ -z "$blockers" ] || { echo "$blockers"; failures+=("open \"blocks release\" issues"); }

# The commit, checked out on its own (the gitignored signing file stays out: nothing is signed here).
tree="$root/build.noindex/release-worktree"
git worktree remove --force "$tree" 2>/dev/null || rm -rf "$tree"
git worktree prune
git worktree add -q --detach "$tree" "$commit"
trap 'git -C "$root" worktree remove --force "$tree" 2>/dev/null || true' EXIT
(cd "$tree" && xcodegen >/dev/null)
derived="$root/build.noindex/release-derived"

step "Builds"
for app in Yomu Miru Kiku Hiku; do
  for platform in iOS macOS; do
    log="$logs/build-$app-$platform.log"
    extra=()
    [ "$platform" = macOS ] && extra=(ARCHS=arm64)
    if (cd "$tree" && xcodebuild build -project Amatsubame.xcodeproj -scheme "$app" -configuration Release \
          -destination "generic/platform=$platform" -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
          ${extra[@]+"${extra[@]}"}) >"$log" 2>&1; then
      echo "  $app ($platform): ok"
    else
      echo "  $app ($platform): FAILED ($log)"; failures+=("$app doesn't build for $platform")
    fi
  done
done

step "Package tests"
for package in "$tree"/Packages/*; do
  [ -d "$package/Tests" ] || continue
  name=$(basename "$package")
  log="$logs/test-$name.log"
  if (cd "$package" && swift test --scratch-path "$root/build.noindex/release-packages/$name") >"$log" 2>&1; then
    echo "  $name: ok"
  else
    echo "  $name: FAILED ($log)"; failures+=("$name's tests")
  fi
done

step "App unit tests"
simulator=${RELEASE_SIMULATOR:-$(xcrun simctl list devices available -j | python3 -I -c '
import json, sys
devices = [d for runtime, ds in json.load(sys.stdin)["devices"].items() if "iOS" in runtime for d in ds]
spare = [d for d in devices if d["name"].startswith("iPhone") and not d["name"].startswith("Amatsubame")]
spare.sort(key=lambda d: d["state"] != "Booted")
print(spare[0]["udid"] if spare else "")')}
if [ -z "$simulator" ]; then
  echo "  no spare iPhone simulator (set RELEASE_SIMULATOR)"; failures+=("app unit tests (no simulator)")
else
  for app in Yomu Miru Kiku; do
    log="$logs/test-${app}Tests.log"
    run_tests() {
      (cd "$tree" && xcodebuild test -project Amatsubame.xcodeproj -scheme "$app" -destination "id=$simulator" \
        -derivedDataPath "$derived-tests" -only-testing:"${app}Tests") >"$log" 2>&1
    }
    # The simulator sometimes can't launch the test host ("failed to launch"); that's worth one more try.
    if run_tests || { grep -q "Simulator device failed to launch" "$log" && run_tests; }; then
      echo "  ${app}Tests: ok"
    else
      echo "  ${app}Tests: FAILED ($log)"; failures+=("${app}Tests")
    fi
  done
fi

step "Kaku tests"
venv="$root/build.noindex/kaku-venv"
if [ ! -x "$venv/bin/python" ]; then
  python3 -m venv "$venv"
  # As in Server/kaku/Dockerfile, without the transcription parts the tests don't load.
  "$venv/bin/pip" install -q fastapi==0.128.8 "uvicorn==0.39.0" pydantic==2.13.5 pytest==8.4.2 httpx==0.28.1 \
    >"$logs/kaku-venv.log" 2>&1
fi
if (cd "$tree/Server/kaku" && "$venv/bin/python" -m pytest -q -p no:cacheprovider tests) >"$logs/test-kaku.log" 2>&1; then
  echo "  ok"
else
  echo "  FAILED ($logs/test-kaku.log)"; failures+=("Kaku's tests")
fi

if [ ${#failures[@]} -gt 0 ]; then
  echo
  echo "Not releasing build $build. What failed:"
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi

step "Hand checks"
echo "  PRs merged since ${previous:-the start}:"
if [ -z "$prs" ]; then
  echo "    (none)"
else
  for pr in $prs; do echo "    #$pr $(gh pr view "$pr" --json title -q .title)"; done
fi
minutes=$build; minutes=${minutes/./}
uploaded=$(date -j -u -f %Y%m%d%H%M "$minutes" +%s 2>/dev/null || echo 0)
hours=$(( ($(date +%s) - uploaded) / 3600 ))
echo "  Build $build was uploaded $hours hours ago."
[ $hours -ge 24 ] || echo "  (That's less than a day in the Dev group.)"
if [ $check_only = 1 ]; then
  echo "All automatic checks passed for build $build (version $version)."
  exit 0
fi
read -r -p "Was every PR above checked by hand, and has build $build been in use in Dev for a day or two? [y/N] " answer
[[ "$answer" =~ ^[Yy] ]] || fail "not confirmed; nothing was tagged."

step "Tagging v$version"
git tag -a "v$version" -m "Amatsubame $version (TestFlight build $build)" "$commit"
git push -q origin "v$version"
gh release create "v$version" --verify-tag --prerelease --generate-notes --title "Amatsubame $version" \
  --notes "TestFlight build $build."

# The next version: the last number goes up, as if the next release only fixes things. The first
# feature merged after it moves main to x.(y+1).0 (the version check above catches a forgotten one).
next="$major.$minor.$(( ${patch:-0} + 1 ))"
main_version=$(git show origin/main:project.yml | sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9.]+)"?.*/\1/p' | head -1)
if [ "$main_version" != "$version" ]; then
  echo "main is already at $main_version; no version PR needed."
else
  step "Moving main to $next"
  bump="$root/build.noindex/release-bump"
  git worktree remove --force "$bump" 2>/dev/null || rm -rf "$bump"
  git worktree add -q -b "version-$next" "$bump" origin/main
  (
    cd "$bump"
    sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*)\"$version\"/\1\"$next\"/" project.yml
    sed -i '' -E "s/^([[:space:]]*\"version\":[[:space:]]*)\"$version\"/\1\"$next\"/" HikuExtension/Resources/manifest.json
    git commit -q -am "Version $next" -m "After releasing $version (build $build)."
    git push -q -u origin "version-$next"
    gh pr create --base main --head "version-$next" --label chore --title "Version $next" \
      --body "Moves main to $next after releasing v$version (TestFlight build $build), so every Dev build carries the version it would ship as. When a feature (idea or enhancement) merges, change it to $major.$((minor + 1)).0 instead."
  )
  git worktree remove --force "$bump"
fi

echo
echo "Released v$version: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/v$version"
echo "Now add build $build to the main tester group: App Store Connect ▸ each app ▸ TestFlight ▸ that group ▸ Builds ▸ +."
