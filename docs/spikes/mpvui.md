# Spike: MPVUI as Miru's player

Branch `spike/mpvui`, not for merging. [MPVUI](https://github.com/LePips/MPVUI) 0.11.0 (pinned): an
MIT Swift wrapper around its own GPL libmpv build (mpv 0.41.0, FFmpeg 9.0.2). It was measured with
the engine lab used for the AetherEngine spike, on the same seven files and the same Mac, so the
numbers sit next to mpv's (Miru's `MPVController`) and AetherEngine's.

## Verdict: viable, not now

MPVUI is the first candidate that could replace Miru's mpv layer without losing anything Miru relies
on. Miru's Japanese lines don't depend on the engine, and MPVUI is lighter on the CPU than Miru's mpv
setup. It also brings picture in picture that plays from mpv itself, with Miru's own overlay. The
port is about 2½–3½ weeks of work, and three things argue for waiting:

- **Pause After Each Line gets less precise** on the sample-buffer output (needed for iOS picture in
  picture): overshoots of whole frames (40–85 ms) where mpv stops within 0–2 ms. Medians stay
  within the 50 ms target, maximums don't.
- **MPVKit has to go entirely** (the two packages can't share a SwiftPM graph), so MediaClipper and
  the scrub thumbnails need FFmpeg from somewhere else.
- **It's young:** external playback is marked experimental, there is a single maintainer, the Mac's
  picture in picture uses a private framework, and there's only a GPL build.

It's worth doing when picture in picture with Miru's own subtitles (Jimaku and Kaku files included)
becomes a priority, or when the timing gets finer.

## Setup
- **Two libmpvs can't coexist.** MPVKit and MPVUI both declare a binary target named `Libmpv-GPL`,
  and SwiftPM refuses to resolve them together. So the lab runs MPVUI in an app of its own,
  `Spikes/MPVUILab`: an `MPVUIBridge` framework, plus `Miru/EngineLab/EngineLab.swift` with `canImport`
  guards so the same lab file still builds in Miru. A port removes MPVKit from Miru.
- `Libmpv.framework` is dynamic (89 MB on the Mac, x86_64 + arm64). It exports only 54 `mpv_*` and
  10 `mpvui_*` symbols and ships only mpv's headers.
- Mac, macOS 27.2.1, M3 Max. Five files were streamed from Jellyfin (test account) and two were
  played locally: HEVC 10-bit + FLAC + ASS (14 fonts), H.264 + AAC + 8 ASS (×2), AV1 + E-AC-3 + SRT
  (×2), HEVC 10-bit + TrueHD + PGS, and H.264 + DTS-HD MA + PGS. A made-up 700-line SRT stood in for a
  Jimaku file.

## 1. Property access
There's no general get or observe and no raw handle (the handle is `package`, and `CMPV` isn't a
product). `setProperty` and `executeCommand` are fire-and-forget. A raw `loadfile` is refused, and so
are the names MPVUI manages (vo, gpu-*, pause, speed, volume…). What Miru uses, mapped:

| Miru | MPVUI |
| --- | --- |
| time-pos, duration, pause, eof-reached | `position`, `duration`, `isPaused`, `state == .ended`; `makeTimingStream`, `makeEventStream` |
| track-list, aid, sid, vid on/off | `mediaInformation.tracks`, `subtitleTracks`; `selectTrack`, `selectSubtitle(_:for:)`, `disableTrack` |
| volume, mute, speed | `setVolume`, `setMuted`, `setPlaybackRate` |
| paused-for-cache, cache-buffering-state, cache-speed | `bufferStatus` (`isBuffering`, `progress`, `inputRate`) |
| chapter-list | `mediaInformation.chapters`, `currentChapterIndex` |
| video-params, video-codec, hwdec-current, audio-codec-name, file-size, dropped frames, container fps | `mediaInformation` (dimensions, codecs, hardware decoder, file size); `playbackDiagnostics` (sampled every 500 ms) |
| seek absolute/relative +exact | `seek(to:)`, `seek(by:)` (both exact), `seekAndWait` with its result |
| sub-add (the English secondary) | `loadExternalSubtitle` / `loadExternalTrack` (no headers: the global `http-header-fields`) |
| frame-step, frame-back-step | `stepForward`, `stepBackward` |
| ab-loop-a/b, sub-margin-x/y, sub-align-y | `setProperty` (allowed) |
| PLAYBACK_RESTART, END_FILE error, log | `isPlaybackReady`, `state == .failed` / `lastError`, `logHandler` |
| http-header-fields, start | `setProperty` before `load`; `load(_:playAutomatically:startTime:)` |
| **none:** osd-width/height, sub-text, audio sample rate | osd size only served Miru's rotation workaround, which MPVUI's own resizing replaces; sub-text is read only in a DEBUG string; the sample rate is only shown in Stats for Nerds |

Init options: Miru's go in `additionalOptions`, applied after MPVUI's own, with managed names
skipped. `.metal` sets the same vo, gpu-api and gpu-context Miru uses. MPVUI forces
`subs-match-os-language` and `subs-fallback`, so Miru has to turn subtitles off itself
(`disableTrack(.subtitle)`). The Mac build has LuaJIT, so Miru's no-scripts options still belong in
`additionalOptions`.

## 2. Timing (Mac)
| | MPVUI sample buffer | MPVUI Metal | mpv (Miru) | AetherEngine |
| --- | --- | --- | --- | --- |
| First frame, remote HEVC10+FLAC | 1.9 s | 3.2 s | 2.8 s | 14.7 s (5.3 s without fonts, 7.74.0) |
| First frame, other files | 0.1–2.2 s | 0.2–2.7 s | | 0.3–1.7 s |
| Exact-seek error | ≤ 29 ms on 3 files, 135–154 ms on 4 | ≤ 71 ms | 0–69 ms | ≤ 1.3 ms local |
| Pause After Each Line overshoot | 0–2, 40–44 or 80–85 ms (whole frames); medians 2–44 ms | medians 0–2 ms in 11 of 14 runs, 40–85 ms in 3; maxima up to 127 ms | 0–2 ms | 2–4 ms |
| 50 rapid seeks, remote DTS-HD MA | 4 stalls, 0 missed | 33 stalls, 30 missed | 6 stalls | 43 stalls, 4 missed (7.73.0); 18, 0 (7.74.0) |
| 50 rapid seeks, other files | 0–3 stalls (1 missed) | 0–8 stalls; TrueHD 6 missed | | |

The sample-buffer output reports the time in frame steps, so a pause at the end of a line lands up
to two frames late. Condensed (rapid seeks) works on both outputs. The Metal output missed many
seeks on the remote DTS file in this run.

## 3. Subtitles
- **Miru's Japanese lines don't depend on the engine.** Miru fetches the Japanese track from
  Jellyfin's subtitle endpoint (Jellyfin extracts embedded ASS: 121 cues per track of the 8-track
  file, 649 for the single-ASS file) and parses it itself. Downloads keep it. Jimaku and Kaku files
  are Miru's own.
- MPVUI's cue APIs (`textSubtitleSnapshots` for the whole track, the interception stream for live
  cues) read SRT, WebVTT, TTML and mov_text, not ASS.
  - Embedded SRT: the whole track (259 cues), covering the playhead again immediately after a
    seek back.
  - Embedded ASS: none.
  - The sidecar file: all 700 cues.
- **English secondary switched on live:** 396 secondary cues next to 259 primary. mpv draws it.
  - Loaded as an external file (as Miru loads Jellyfin's English track), it blocks MPVUI's AirPlay
    ("External track files are not supported"). See 7.

## 4. Mining
- **MediaClipper can't use MPVUI's FFmpeg:** it's merged into `Libmpv.framework` and not exported.
  It needs its own copy, and MPVKit's FFmpeg can't stay, because MPVKit itself can't.
- **No screenshots from MPVUI:** its FFmpeg has no image encoder ("Could not open libavcodec encoder
  for saving images"), and on the sample-buffer output mpv can't convert VideoToolbox frames either.
  Miru's stills and animated clips already come from MediaClipper, so that path stays as it is,
  with its own FFmpeg.

## 5. Picture in picture
- **iPad simulator:** starts in 0.6–0.7 s with the `.videoOverlay` line on
  (`isVideoOverlayActive`), and stops cleanly. Miru's current AVPlayer hand-off takes several seconds
  or more. The simulator shows a black PiP window in screenshots, so the overlay in the small window
  still needs a check on a device.
- **The overlay** is SwiftUI rasterized with `ImageRenderer` only when it changes, at most 30
  updates/s and 2048 px, then drawn by mpv into the frames. A Miru line changes a few times a minute,
  so the cost is small; the copy in the small window isn't interactive.
- **This would fix PiP's current limits:** Jimaku and Kaku lines, timing fixes and the English
  secondary all show, with no transcode, and the same player keeps going.
- iOS PiP needs the sample-buffer output (see 2 for its timing).

## 6. Rendering
- **Steady playback of the remote HEVC 10-bit file** (the lab's small view, 60 s, the app process):

  | | App CPU, median (max) | GPU utilization, median (max) |
  | --- | --- | --- |
  | MPVUI sample buffer | 6% (15%) | 4.5% (19%) |
  | MPVUI Metal | 14% (20%) | 8% (9%) |
  | mpv in Miru (gpu-next on MoltenVK) | 20% (29%) | 10% (12%) |

  Both MPVUI outputs use less than Miru's mpv. The sample-buffer output leaves scaling to
  AVFoundation, so mpv's gpu-next scalers and debanding are gone; Metal keeps them. A side-by-side
  picture comparison at full screen is still to do on a device.
- **The output is fixed per player.** Switching means a new player at the current position: a
  reload, about the first-frame times above (0.2–3 s). Moving the picture to another layer (Miru's
  external-display scene) also recreates the mpv handle at the last position, a brief reload.
  Miru's current single-layer move has none.
- **Rotation:** MPVUI resizes its surface itself (`external-surface-size`), so Miru's rotation nudge
  goes away. Not exercised on the simulator.

## 7. External playback (AirPlay)
`externalPlayback` is experimental. Its plan comes from `makePreparationPlan`. Every plan except
direct playback serves local HLS from the device, so the TV never needs to reach Jellyfin (Miru's
new AVPlayer path does need that). With mpv's subtitles off, as Miru plays:

| File | Plan |
| --- | --- |
| H.264 + AAC (remote and local) | remuxing |
| HEVC10 + FLAC, HEVC10 + TrueHD, H.264 + DTS-HD MA | audio transcoding (video copied) |
| AV1 + E-AC-3 (remote and local) | video transcoding (H.264 encoded on the device) |

With a subtitle selected, every file needs **rendering** (mpv re-encodes the picture as H.264 SDR
to burn the subtitle in). That's the only way Miru's line would reach the TV. Loading an external
subtitle file (Miru's English) makes the plan fail. The real check needs the owner's Apple TV.

## 8. The Mac
Playback works and is lighter than Miru's mpv (6). Picture in picture works: active in about 0.1 s
with the overlay on, stopping cleanly, on all seven files. It uses the private `PIP.framework` (the
code says so), which App Review can reject. Miru's Mac builds go through TestFlight and Developer ID;
for an App Store release, Mac PiP would have to stay off.

## 9. Port estimate
About **2½–3½ weeks**:
- **`MPVController` on MPVUI's `MPVPlayer`, keeping its API** so `PlaybackModel` and the views
  hardly change (they read `model.mpv.*` in about 200 places): 3–4 days. Some things are lost or
  rewired: osd size (dropped), sub-text (debug only), the subtitle options (via `disableTrack`), and
  the English secondary through `loadExternalSubtitle`.
- **FFmpeg for MediaClipper and the scrub thumbnails without MPVKit:** an FFmpeg xcframework
  package (AetherEngine's FFmpegBuild, or a build of our own, LGPL), with symbol isolation checked:
  2–4 days.
- **PiP:** MPVUI's own in place of the AVPlayer hand-off, the Japanese line through `.videoOverlay`,
  and sample-buffer output when PiP is likely (or for good): 2–3 days, plus a device check.
- **External display** with the handle being recreated (a brief reload), and the AirPlay video
  just shipped kept as it is (MPVUI's is experimental and can't carry Miru's line without
  rendering): 1–2 days.
- **Pause After Each Line and Condensed** on frame-stepped time (pausing a frame early, or
  `ab-loop-b`): 1–2 days.
- **Tests:** UI tests, the PiP and external-display tests, and the macOS builds: 2–3 days.

Risks:
- Timing precision on the sample-buffer output.
- The experimental external-playback API.
- A single maintainer.
- The GPL-only build (allowed: Miru is GPL-3.0).
- The private framework on the Mac.
- Missed seeks with Metal on remote DTS-HD MA (seen once).
- Untested on a device: battery, PiP visuals, AirPlay.

## Not tested
Battery, real AirPlay, the PiP overlay on a device, rotation and fold on a simulator, and picture
quality side by side at full screen.
