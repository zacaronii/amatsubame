# hoshidicts (vendored)

Yomitan dictionary importer and lookup engine by Manhhao.

- Upstream: https://github.com/Manhhao/hoshidicts (branch `main`)
- Commit: `e6af33e1ab3241e16b885ec81f048f05d81f766b` (2026-10-14, "fix: read media on on demand")
- License: GPL-3.0 (`LICENSE`). Bundled dependencies keep their own licenses under `external/*`:
  glaze (MIT), libdeflate (MIT), unordered_dense (MIT), utf8proc (MIT), utfcpp (BSL-1.0), xxHash (BSD-2-Clause).
  zstd (BSD) comes from its SwiftPM package.
- Why `main` and not the MIT branch (`main-mit`): `main-mit` is an older snapshot (last updated
  2026-04-27) without the C API we call, Yomitan's deinflection rules and preprocessor, or later fixes.
  hoshidicts is linked into every app, so the apps are GPL-3.0 (the repository's `LICENSE`). An App
  Store release would need the hoshidicts author's permission, since Apple's terms add restrictions
  the GPL doesn't allow.

## What's included
`src`, `include`, `LICENSE`, `README.md`, and only the build-relevant parts of the submodules
under `external/` at the commits pinned upstream:
glaze `dda11044`, libdeflate `b122c8be`, unordered_dense `e5b9441e`, utf8proc `0075ed7d`, utfcpp `c5585ef8`, xxHash `c0b5ea99`.
Left out: `cli`, `benchmark`, tests and docs, `external/zstd` (SwiftPM package instead), `external/kanji-processor` (TypeScript tooling, not part of the C++ build).

## Local patches
1. `include/module.modulemap` exposes only `hoshidicts_c.h` (no `requires cplusplus`), so Swift
   imports `CHoshiDicts` through plain C interop and C++ interop never spreads to the app.
2. `Package.swift` drops the CLI executable target and the `.interoperabilityMode(.Cxx)` Swift setting.

The C++ sources are unchanged.

## Updating
Clone upstream with `--recurse-submodules` into an empty folder, copy the same paths over this
directory, reapply the two patches above, update the commit hashes here, then run the
Dictionary package tests.
