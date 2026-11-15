#!/bin/bash
# Moves Vendor/hoshidicts to the hoshidicts commit a Hachidori release ships
# (bee-san's fork, pinned as Hachidori's third_party/hoshidicts submodule).
# See Vendor/hoshidicts/VENDORED.md.
#
#   scripts/update-hoshidicts.sh [<Hachidori version>]   copy that release's engine in (default: the latest release)
#   scripts/update-hoshidicts.sh --check                 exit 1 when the latest release ships another commit
#
# Needs git and gh. After an update, read what it prints (C API, Package.swift
# and format changes), run `swift test` in Packages/Dictionary and build the apps.
set -euo pipefail
cd "$(dirname "$0")/.."

vendor=Vendor/hoshidicts
fork=https://github.com/bee-san/hoshidicts.git
engine_swift=Packages/Dictionary/Sources/Dictionary/DictionaryFormat.swift

current_commit=$(sed -n 's/^- Commit: `\([0-9a-f]*\)`.*/\1/p' "$vendor/VENDORED.md")
current_release=$(sed -n 's/^- Hachidori: `\([^`]*\)`.*/\1/p' "$vendor/VENDORED.md")

pinned_commit() {
  gh api "repos/bee-san/hachidori/contents/third_party/hoshidicts?ref=$1" --jq .sha
}

if [[ ${1:-} == --check ]]; then
  latest=$(gh api repos/bee-san/hachidori/releases/latest --jq .tag_name)
  commit=$(pinned_commit "$latest")
  if [[ $commit == "$current_commit" ]]; then
    echo "Up to date: Hachidori $latest ships hoshidicts ${commit:0:8}."
    exit 0
  fi
  echo "Hachidori $latest ships hoshidicts ${commit:0:8}; Vendor/hoshidicts has ${current_commit:0:8} (Hachidori $current_release)."
  echo "Changes: https://github.com/bee-san/hoshidicts/compare/$current_commit...$commit"
  exit 1
fi

release=${1:-$(gh api repos/bee-san/hachidori/releases/latest --jq .tag_name)}
commit=$(pinned_commit "$release")
echo "Hachidori $release ships hoshidicts ${commit:0:8}."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
src=$tmp/src
git clone -q "$fork" "$src"
git -C "$src" checkout -q "$commit"
git -C "$src" submodule update -q --init \
  external/glaze external/libdeflate external/unordered_dense external/utf8proc external/utfcpp external/xxHash

# Our three files stay; everything else is replaced.
mkdir "$tmp/keep" "$tmp/keep/include"
cp "$vendor/Package.swift" "$vendor/VENDORED.md" "$tmp/keep/"
cp "$vendor/include/module.modulemap" "$tmp/keep/include/"
rm -rf "$vendor"
mkdir -p "$vendor/external"

cp -R "$src/LICENSE" "$src/README.md" "$src/src" "$src/include" "$vendor/"
cp "$tmp/keep/Package.swift" "$tmp/keep/VENDORED.md" "$vendor/"
cp "$tmp/keep/include/module.modulemap" "$vendor/include/"
# Patch 3: zstd comes unmodified from its SwiftPM package (see VENDORED.md).
rm -rf "$vendor/src/zstd"
rm -f "$vendor/src/languages/generate_case_tables.mjs"

copy_external() {  # <library> <paths…>
  local library=$1; shift
  mkdir -p "$vendor/external/$library"
  for path in "$@"; do cp -R "$src/external/$library/$path" "$vendor/external/$library/"; done
}
copy_external glaze include LICENSE
copy_external libdeflate common_defs.h COPYING lib libdeflate.h
copy_external unordered_dense include LICENSE
copy_external utf8proc LICENSE.md utf8proc_data.c utf8proc.c utf8proc.h
copy_external utfcpp LICENSE source
copy_external xxHash LICENSE xxh3.h xxhash.h
copy_external lzokay LICENSE README.md lzokay.cpp lzokay.hpp
copy_external gumbo-parser LICENSE LICENSE-hashmap.c README.md UPSTREAM-README.md src

# Record the new pin.
line=$(git -C "$src" log -1 --format='%cs, "%s"' "$commit")
sed -i '' \
  -e "s|^- Commit: .*|- Commit: \`$commit\` ($line)|" \
  -e "s|^- Hachidori: .*|- Hachidori: \`$release\` (its \`third_party/hoshidicts\` submodule)|" \
  "$vendor/VENDORED.md"
sed -i '' "s|^glaze \`.*|$(
  cd "$src"
  for m in glaze libdeflate unordered_dense utf8proc utfcpp xxHash; do
    printf '%s `%s`, ' "$m" "$(git -C "external/$m" rev-parse --short=8 HEAD)"
  done | sed 's/, $/./'
)|" "$vendor/VENDORED.md"

# What a person needs to read before merging.
echo
if git -C "$src" cat-file -e "$current_commit^{commit}" 2>/dev/null; then
  echo "== C API (include/hoshidicts_c.h) since ${current_commit:0:8}:"
  git -C "$src" diff --stat "$current_commit" "$commit" -- include/hoshidicts_c.h
  git -C "$src" diff "$current_commit" "$commit" -- include/hoshidicts_c.h | grep '^[-+][^-+]' | grep '^-' \
    && echo "   ^ removed or changed lines: the Swift wrapper may need changes." || echo "   Additions only."
  echo
  echo "== Upstream Package.swift (sources and header paths ours must match):"
  git -C "$src" diff "$current_commit" "$commit" -- Package.swift || true
else
  echo "== ${current_commit:0:8} isn't in the fork's history: compare include/hoshidicts_c.h and Package.swift by hand."
fi
newest=$(grep -o '\.hoshidicts_[0-9]*' "$vendor/src/query.cpp" | sed 's/.*_//' | sort -n | tail -1)
known=$(sed -n 's/.*static let newest = \([0-9]*\).*/\1/p' "$engine_swift")
echo
if [[ $newest == "$known" ]]; then
  echo "== Dictionary format: the engine reads up to .hoshidicts_$newest, as DictionaryFormat.newest says."
else
  echo "== Dictionary format: the engine now reads up to .hoshidicts_$newest; set DictionaryFormat.newest (now $known) to match."
fi
echo
echo "Next: swift test in Packages/Dictionary, build the four apps, and open a PR into dev."
