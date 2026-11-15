# hoshidicts (vendored)

Yomitan dictionary importer and lookup engine, from bee-san's fork of Manhhao's hoshidicts: the engine
[Hachidori](https://github.com/bee-san/hachidori) ships.

- Upstream: https://github.com/bee-san/hoshidicts (fork of https://github.com/Manhhao/hoshidicts)
- Commit: `088ac5ded9e4de62a0c3f434f3f72350945459a3` (2026-11-08, "Merge pull request #88 from bee-san/perf/zip-read-on-demand")
- Hachidori: `0.5.2` (its `third_party/hoshidicts` submodule)
- License: GPL-3.0 (`LICENSE`). Bundled dependencies keep their own licenses under `external/*`:
  glaze (MIT), libdeflate (MIT), unordered_dense (MIT), utf8proc (MIT), utfcpp (BSL-1.0), xxHash (BSD-2-Clause),
  lzokay (MIT), gumbo-parser (Apache-2.0). zstd (BSD) comes from its SwiftPM package.
  hoshidicts is linked into every app, so the apps are GPL-3.0 (the repository's `LICENSE`). An App
  Store release would need permission from the hoshidicts authors (Manhhao and bee-san), since Apple's
  terms add restrictions the GPL doesn't allow.

## Why bee-san's fork
It's the engine a Hachidori host uses, so the apps can load the dictionaries a host exports (its
compiled folders, format markers `.hoshidicts_5`/`_6`) and rank results as the host does. Upstream
has since written a different `.hoshidicts_5`; the two formats must never be mixed. The fork still
reads the `_1`–`_4` folders the earlier upstream engine wrote, so installed dictionaries keep working.
Background: docs/hachidori.md, section 7.

## Which commit
The one the latest Hachidori release pins as `third_party/hoshidicts`, not the fork's `main`. A newer
engine reads every older format, so the apps can be ahead of a host but not behind it.
`.github/workflows/hoshidicts-check.yml` runs `scripts/update-hoshidicts.sh --check` every week and
opens an issue when a release ships another commit.

## What's included
`src`, `include`, `LICENSE`, `README.md`, and only the build-relevant parts of the libraries under
`external/`, at the commits the fork pins:
glaze `dda11044`, libdeflate `b122c8be`, unordered_dense `e5b9441e`, utf8proc `0075ed7d`, utfcpp `c5585ef8`, xxHash `c0b5ea99`.
lzokay and gumbo-parser are copied files in the fork (each with its README naming its source).
Left out: `cli`, `benchmark`, `tests`, `tools`, `docs`, `languages` (Japanese is built in; other
language packs load at run time and the apps don't use them), `external/zstd` (SwiftPM package
instead), `external/kanji-processor` (TypeScript tooling).

## Local patches
1. `include/module.modulemap` exposes only `hoshidicts_c.h` (no `requires cplusplus`), so Swift
   imports `CHoshiDicts` through plain C interop and C++ interop never spreads to the app.
2. `Package.swift` drops the CLI executable target and the `.interoperabilityMode(.Cxx)` Swift setting,
   and requires iOS and macOS 26 like the apps (the fork's language packs parse numbers with
   `std::from_chars` for floating point, which Apple's C++ library has only from 26).
3. `src/zstd/zstd_compress_sequences.c` is left out. The fork's CMake build swaps it into zstd to
   build zstd's default table once per import (the bytes written are identical); SwiftPM can't
   replace a file in a package dependency, so zstd stays stock and imports are slightly slower.

The C++ sources are otherwise unchanged.

## Updating
`scripts/update-hoshidicts.sh [<Hachidori version>]` copies the engine of that release (default: the
latest), keeps the three patched files, updates the commits above and prints what to check:
- **C API:** the diff of `include/hoshidicts_c.h`. Additions need nothing; a changed or removed
  declaration needs the Swift wrapper in `Packages/Dictionary` changed.
- **Package.swift:** the fork's source list and header paths; copy new ones into ours.
- **Format:** the newest `.hoshidicts_N` the engine reads, which `DictionaryFormat.newest` must match.

Then run `swift test` in `Packages/Dictionary` (and the real-dictionary tests, docs/shared.md), build
the four apps and open a PR into `dev`.
