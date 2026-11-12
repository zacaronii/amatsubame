# libfvad (vendored)

Voice activity detection from WebRTC, as a standalone C library by Daniel Pirch. alass uses
the same detector (through the `webrtc-vad` crate) to find speech in a video's audio. Here it
finds speech for Miru's subtitle Auto-Sync (`PlayerKit/SpeechDetector.swift`).

- Upstream: https://github.com/dpirch/libfvad (branch `master`)
- Commit: `532ab666c20d3cfda38bca63abbb0f152706c369` (2024-02-19, "Fix C11 compiler support check in configure.ac")
- License: BSD-3-Clause (`LICENSE`; the WebRTC project authors and Daniel Pirch).

## What's included
`src` (without its `CMakeLists.txt` and `Makefile.am`), `include`, `LICENSE`, `README.md`.
Left out: `examples`, `tests` and the autotools/CMake build.

## Local additions
1. `Package.swift` builds `src` as the C target `CFVad`.
2. `include/module.modulemap` exposes `fvad.h` as the module `CFVad`.

The C sources are unchanged.

## Updating
Copy `src`, `include/fvad.h`, `LICENSE` and `README.md` from a newer upstream commit over this
directory (drop the build files again), update the commit here, then run the `Packages/Player` tests (`swift test`).
