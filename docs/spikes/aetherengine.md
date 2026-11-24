# Spike: AetherEngine as Miru's video engine

Branch `spike/aetherengine`, not for merging. AetherEngine 7.73.0 (pinned in project.yml) sits behind a
small `PlayerEngine` protocol (`Packages/PlayerEngine`) next to mpv (`MPVPlayerEngine`), and an engine
lab (`Miru/EngineLab`, Debug only, `UITEST_ENGINE_LAB=<config.json>`) runs the same steps on both.
mpv stays the default; nothing in the shipping player changed.

## Verdict: no-go for now

AetherEngine matches or beats mpv on the measurements that matter for Pause After Each Line and
exact seeks, and links cleanly next to MPVKit. It isn't ready to replace mpv for Miru:

- **Embedded ASS tracks can come back empty.** On one of the two ASS test files, the side reader got
  no packets for any of its eight ASS tracks (`subtitle-delivery … packets=0 … outcome=empty`), local
  and remote, with native subtitles on or off. mpv shows them. Most of Miru's subtitles are ASS, and
  tappable lines need the text.
- **Remote DTS fell apart under seeking:** 43 freezes and 4 missed seeks out of 50 (worst 25 s), a
  failed snapshot (28 s), and 200–400 ms pause overshoots. mpv had 6 freezes on that file.
- **Slow first frame on remote HEVC 10-bit + FLAC:** 14.7 s (mpv 2.8 s).
- The draw (AVPlayer: PiP, AirPlay, Now Playing) is still unmeasured: the Mac lab can't show it,
  and the iOS Simulator lab crashed in mpv's MoltenVK path before reaching it.

Worth looking at again when AetherEngine fixes the ASS reader, with an aether-only run on a device for
PiP, AirPlay and external display. Reported upstream (against 7.73.0): AetherEngine #1127 (ASS),
#1128 (remote DTS) and #1129 (first frame).

## Setup

- Mac (macOS 27.2), Debug build, ad-hoc signed lab bundle ID. Five files streamed from Jellyfin
  (`static=true`, direct play) and two of them downloaded and played locally:
  HEVC 10-bit + FLAC + ASS, H.264 + AAC + ASS (×2), AV1 + E-AC-3 + SRT (×2), HEVC 10-bit + TrueHD +
  PGS, H.264 + DTS + PGS. A made-up 700-line SRT stood in for a Jimaku file.
- mpv: Miru's own `MPVController` (videotoolbox, `gpu-next`).
- AetherEngine: `LoadOptions` with `prepareNativeSubtitles` (the lab can switch it off with
  `AETHER_NATIVE_SUBS=0`).

## Results

### 1. Route and audio
Every file took AetherEngine's **loopback** route (local HLS server → AVPlayer). Audio was
**stream copy** for AAC, E-AC-3 and FLAC, **bridged** (decoded) for TrueHD and DTS. Rate up to 2×.

### 2. Exact seeks (6 per file)

| | AetherEngine | mpv |
| --- | --- | --- |
| Error, local files | ≤ 1.3 ms every seek | 0–69 ms (often one frame) |
| Error, remote | mostly ≤ 4 ms; 5 of 30 seeks off by 63–323 ms (H.264+AAC, HEVC+FLAC) | 0–49 ms |
| Latency, local | 0.04–0.12 s | 0.03–0.19 s |
| Latency, remote | 0.01–3.1 s (one 6.3 s first seek) | 0.07–1.85 s |

### 3. 50 seeks in 60 s (Line skip, Condensed)

| File | AetherEngine freezes / missed / worst | mpv freezes / worst |
| --- | --- | --- |
| Local files, remote AAC/E-AC-3/FLAC | 0 / 0 / ≤ 1.9 s | 0 / ≤ 2.0 s |
| Remote TrueHD | 6 / 0 / 1.5 s | 10 / 4.9 s |
| Remote DTS | **43 / 4 / 25 s** | 6 / 2.0 s |

### 4. Pause After Each Line overshoot (median, 8 lines)
- AetherEngine with AVPlayer's boundary observer: **1.6–2.0 ms at 1×, 3.4–3.9 ms at 2×** (max 8 ms),
  except remote DTS (outliers of 200 and 400 ms). Polling AetherEngine's clock instead is ~100 ms
  (it updates at ~10 Hz), so a port has to use boundary observers.
- mpv (time events): 0–2 ms at both rates.

### 5. Cues
- SRT: cues published, 10-minute seek back covered again in 0.2–0.5 s.
- ASS: on the file that worked, `\N` became a newline and style tags were stripped (0 cues with
  `{\` or `\N` left). On the other ASS file: no cues at all (above).
- Sidecar (the Jimaku stand-in): all 700 lines.
- Primary + secondary at once: 26 primary and 28 secondary cues side by side.

### 6. Mining
- Snapshot (`FrameExtractor`, full resolution): 0.04–0.23 s local, 0.8–2.0 s remote; failed on
  remote DTS. mpv: 0.06–0.7 s local, 0.9–9.7 s remote (scaled to 1280).
- `MediaClipper`'s 3 s audio clip worked next to both engines on every file.
- Linking: AetherEngine's FFmpeg is its own (the AetherLib* frameworks inside AetherBridge.framework);
  `nm -m` shows all 162 of AetherBridge's FFmpeg imports bound to them, none to MPVKit's FFmpeg built
  into Miru, and no AetherEngine symbols in Miru itself.

### 7–9. System, battery, Mac
- PiP, AirPlay, external display, background audio: **untested** (needs a device run; see verdict).
- Now Playing: AetherEngine publishes nothing itself; Miru would keep doing it.
- Battery: **untested**.
- Mac: everything above ran on the Mac.

## A lab bug worth knowing
The first Mac runs crashed in Swift's main-actor check during a SwiftUI redraw. The cause was the lab:
`JSONSerialization` raises an Objective-C exception on NaN (a seek that never landed); AppKit caught
it in the middle of the lab's task, leaving that task's executor record on the main thread, and the
next redraw crashed on it. The lab now writes NaN as null. AetherEngine wasn't at fault.

## Migration estimate (if it becomes a go)
Miru talks to mpv in about 170 places, nearly all in `PlaybackModel` (~2,000 lines), plus
`MPVController`, `MPVVideoView`, `ExternalDisplay` and the PiP hand-off. Moving them behind
`PlayerEngine` and onto AetherEngine, with boundary-observer pauses, AVPlayer PiP and AirPlay in place
of the sample-buffer hand-off, and the UI tests: **about 3–4 weeks**, plus whatever the ASS fix takes
upstream. Shipping both engines side by side for a while adds the app-size cost of a second FFmpeg.
