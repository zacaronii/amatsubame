#!/bin/bash
# Compares our tap lookups with Hachidori's own engine, on the same dictionaries.
#
#   scripts/hachidori-parity.sh                  the committed sample (Packages/Lookup/Tests/LookupTests/Fixtures/parity-sample.tsv): every tap must match
#   scripts/hachidori-parity.sh <corpus.tsv>     a corpus (scripts/parity-corpus.py writes one); prints the report
#
# The dictionaries are copied, read only, from the Hachidori host in HACHIDORI_LINK_URL (or .env's),
# and Hachidori's engine is the hoshidicts.wasm of the release Vendor/hoshidicts/VENDORED.md names
# (the one our vendored engine comes from), run with Node with the host's own frequency sorting (which
# our side follows too, as a linked app does). Our deliberate differences are applied to its results
# before comparing: redirects ranked as Yomitan does, and converted names after words. Work files go
# in build.noindex/parity (the copied dictionaries are kept).
#
# Needs git, node and python3.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z ${HACHIDORI_LINK_URL:-} && -f .env ]]; then
  HACHIDORI_LINK_URL=$(sed -n 's/^HACHIDORI_LINK_URL=//p' .env | head -1 | sed "s/^[\"']//; s/[\"']$//")
fi
: "${HACHIDORI_LINK_URL:?set HACHIDORI_LINK_URL (ws://<host>:8771/link) to the host whose dictionaries to copy}"
export HACHIDORI_LINK_URL

release=$(sed -n 's/^- Hachidori: `\([^`]*\)`.*/\1/p' Vendor/hoshidicts/VENDORED.md)
work=$PWD/build.noindex/parity
checkout=$work/hachidori-$release
mkdir -p "$work"
if [[ ! -f $checkout/extension/vendor/hoshidicts.wasm ]]; then
  echo "• Hachidori $release"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$release" https://github.com/bee-san/hachidori.git "$checkout"
fi

corpus=${1:-}
# Fails when the test does (a sample tap that differs, or a setup error).
run_tests() {
  local log=$work/test.log status=0
  (cd Packages/Lookup && env PARITY_WORK="$work" ${corpus:+"PARITY_CORPUS=$corpus"} "$@" swift test --filter HachidoriParityTests) > "$log" 2>&1 || status=$?
  grep -E '^Parity:|✘|error:' "$log" || true
  return $status
}
echo "• Copying the host's dictionaries and the texts to look up"
run_tests
echo "• Hachidori's engine"
node scripts/parity-reference.mjs "$checkout" "$work/manifest.json" "$work/options.json" "$work/texts.txt" "$work/reference.jsonl"
echo "• Comparing"
run_tests PARITY_REFERENCE="$work/reference.jsonl" PARITY_OUTPUT="$work/lookups.jsonl"
if [[ -n $corpus ]]; then
  python3 scripts/parity-report.py "$work/lookups.jsonl"
fi
