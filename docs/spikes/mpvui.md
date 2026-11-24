# Spike: MPVUI as Miru's player (work in progress)

Branch `spike/mpvui` (from the AetherEngine spike, so the same engine lab measures all three), not
for merging. MPVUI 0.11.0 (LePips/MPVUI, pinned). Status: first run done (sample-buffer output, 7
files, Mac); the Metal-output run, the iOS/PiP checks and the report itself are still to do.

## Setup found so far
- **MPVKit and MPVUI can't share a package graph:** both declare a binary target named `Libmpv-GPL`,
  and SwiftPM refuses to resolve them together. So the lab runs MPVUI in its own app,
  `Spikes/MPVUILab` (xcodegen; `MPVUIBridge` framework + `Miru/EngineLab/EngineLab.swift`, with
  `canImport` guards so the same lab file builds in Miru too). A port would remove MPVKit from Miru
  entirely; MediaClipper then needs FFmpeg from somewhere else.
- **MPVUI's FFmpeg isn't usable by MediaClipper:** `Libmpv.framework` (dynamic, 89 MB on the Mac,
  x86_64 + arm64) exports only 54 `mpv_*` and 10 `mpvui_*` symbols and ships only mpv's headers.
- **Only a GPL build exists** (mpv `-Dgpl=true`, FFmpeg `--enable-gpl --enable-version3`); Miru uses
  MPVKit's LGPL build today. Miru is GPL-3.0, so it's allowed, but it's a change.
- **API:** no general getProperty/observeProperty and no raw handle; `setProperty` and
  `executeCommand` are fire-and-forget. Most of what Miru reads has a typed equivalent (position,
  duration, pause, tracks, buffer, chapters, codecs, hwdec, dropped frames); none for
  `osd-width/height` (only Miru's rotation workaround, which MPVUI's own resizing replaces),
  `sub-text` (debug only) and the audio sample rate. `load` takes no headers: `http-header-fields`
  via `setProperty` first.
- **Subtitles:** Miru doesn't need mpv's text: it parses the Japanese track it fetches from
  Jellyfin (Jellyfin extracts embedded ASS: 121 cues per track of the 8-track file, 649 for the
  single-ASS file) and downloads keep it. MPVUI's cue APIs read SRT/WebVTT/TTML/mov_text only, not ASS.
- Output (Metal or sample buffer) is fixed per player; moving the picture to another layer (our
  external display) recreates the mpv handle. iOS PiP needs sample-buffer output; Mac PiP uses the
  private PIP.framework.

## First run: sample-buffer output, Mac
| | MPVUI | mpv | AetherEngine |
| --- | --- | --- | --- |
| First frame, remote HEVC10+FLAC | 1.9 s | 2.8 s | 14.7 s |
| First frame, others | 0.1–2.2 s | | 0.3–1.7 s |
| Exact-seek error | up to 135–154 ms on 4 files, ≤ 29 ms on 3 | 0–69 ms | ≤ 1.3 ms local |
| Pause After Each Line overshoot | 0–2, 40–44 or 80–85 ms (whole frames); medians 2–44 ms | 0–2 ms | 1.6–4 ms |
| 50 rapid seeks, remote DTS | 4 freezes, 0 missed | 6 freezes | 43 freezes, 4 missed |
| 50 rapid seeks, others | 0–3 freezes (1 missed on HEVC10+FLAC) | | |
| Cues: embedded SRT | whole track (259), covered at once after a seek back | n/a | |
| Cues: embedded ASS | none (not supported) | n/a | one file empty |
| Sidecar (700 lines) | all 700 | n/a | all 700 |
| Snapshot (mpv's screenshot of the video) | fails: VideoToolbox frames can't be converted | | |

## To do
Metal-output run (quality, CPU/GPU, overshoot and seeks), PiP with the SwiftUI overlay on the iPad
simulator, the external-playback plan per file, rotation/fold resizes, Mac playback and PiP, the
English secondary live, and the port estimate. The lab's Jellyfin session was signed out at the
pause; a new one is made for the next run.
