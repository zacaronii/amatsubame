# Miru: moving playback from mpv to AetherEngine

This is the plan for moving Miru's player from mpv (MPVKit) to
[AetherEngine](https://github.com/superuser404notfound/AetherEngine). Nothing in it is built
yet. The battery comparison (Miru 202611271629) is in (below); it starts when the owner decides
to go ahead. The evidence so far is the spike on `spike/aetherengine`
(`docs/spikes/aetherengine.md` there):
- a Mac lab run against 7.73.0, then 7.76.0;
- the owner's device run on 7.76.0 ("everything seemed to work well");
- the battery comparison on the iPhone.

## Battery comparison (2026-11-27)

The owner played the same episode for 25 minutes with each engine on the spike build
202611271629, with Settings ▸ Test ▸ "Don't record playback" on for the mpv run, so neither run
reached Stats, Jellyfin or kechimochi.

| Engine | Battery | Drain |
| --- | --- | --- |
| AetherEngine | 90% → 88% | 2 points |
| mpv | 88% → 85% | 3 points |

iOS shows the battery in whole points, so each reading can be off by up to a point: this says
AetherEngine is level with mpv or slightly better, not by how much. It passes phase 0's battery
bar. It was one file, so it covers the route that file took; the software route's cost is
measured per codec in phase 2's device testing (below).

## Why, and why carefully

**What AetherEngine gives Miru:**
- AVPlayer for most files. That brings picture in picture, AirPlay, Now Playing and external
  displays from the system, in place of Miru's own hand-offs: `PictureInPicture.swift`,
  `AirPlayVideoHandoff` and the transcodes they start on Jellyfin.
- A faster first frame on HEVC 10-bit: about 1.0 s, against 2.8 s on mpv.
- An active upstream that fixed all three bugs we reported within days.

**Why carefully:**
- AetherEngine is a young, single-maintainer project that is openly vibe-coded. It releases
  fast (7.73 → 7.76 in days) and depends on its own FFmpeg build.
- Its subtitle cues are plain text. Styled ASS (signs, positioned English) is something mpv
  draws and it doesn't.

**So every phase:**
- keeps mpv in the app until the very last phase;
- has a measurable gate before the next phase starts;
- has an exit path that leaves Miru as good as it is today.

## Principles

- **mpv stays the safety net.** Until phase 5, every build can still play any file with mpv,
  and the owner can force it per episode.
- **One engine interface.** `PlaybackModel` talks to a `PlayerEngine` protocol, never to mpv or
  AetherEngine directly. Leaving AetherEngine means deleting one conformance.
- **Our features don't move into the engine.** These stay ours:
  - the tappable lines and lookup;
  - Pause After Each Line;
  - subtitle sync (libfvad);
  - Jimaku and Kaku subtitles;
  - card media (`MediaClipper`);
  - progress and Stats.
- **Pinned exactly, upgraded on purpose** (see Version pinning).
- **No data migrations tied to the engine.** A rollback to the mpv build must open the same
  database (see Rollback).

## Phase 0: backup and groundwork (no player change)

**Done on 2026-11-27** (the owner's go came the same day). What was done, where it differs from the
steps below:
- **Backup:** tag `mpv-final-2026-11-27` on 2e41370, the commit of Dev build 202611271555, which is
  already on TestFlight and notarized for the Mac. Its Miru is the same code as dev's head then
  (307a9a3 only changed scripts), so no new build was needed.
- **Mac zip:** on a release `mpv-final-2026-11-27` in the **tap** repo, not the app repo. A release
  in the app repo would have run the Kaku image workflow (from the tagged commit, before #327's
  guard) and moved Kaku's `latest` image to unreleased code. `miru@mpv` is in the tap.
- **Scripts:** #327 (`--ios-only`, the backup in the cask conflicts, the Kaku guard).
- **Pins:** see Version pinning. LibDovi, SMBClient and LibTrueHD (also AetherEngine dependencies)
  are pinned exactly at upstream; forking them too is an open question.
- **Notices:** added on the spike branch, which is the only place AetherEngine is built. Dev's
  `THIRD_PARTY_NOTICES.md` gets them in the PR that adds the package (phase 2).
- **Rehearsal:** on a simulator, dev → spike → dev → spike over the same data (a Stats session, a
  resume point, a finished download and its file, player settings and a preference). Everything
  stayed and each build launched; the spike adds no migrations. The simulator had no server account,
  so this checks the data and the launch, not the screens that show them.
- **Still to do for the gate:** the owner installs the backup on the iPhone, the iPad and the Mac.

**1. The mpv backup.** Made on the last dev commit before any AetherEngine code merges:
- Tag it `mpv-final-<YYYY-MM-DD>` and push the tag.
- Make a Dev build from it and note the build number in the tag message. Its TestFlight build
  stays installable for 90 days (TestFlight ▸ Miru ▸ Previous Builds).
- Mac: attach that build's notarized `Miru-<version>-<build>.zip` to a GitHub pre-release
  named for the tag in the app repo, so it never becomes "latest".
- Add a pinned `miru@mpv` cask to the tap:
  - fixed version and sha;
  - `livecheck skip`;
  - `conflicts_with` `miru` and `miru@dev` (and they with it);
  - the same `zap`.
  - It isn't written by `upload-dev.sh`, so Dev builds never move it.

**2. Scripts.**
- `upload-dev.sh --ios-only`, so a backup or test build can go to TestFlight without touching
  the Homebrew casks. Today a hand-run copy does this.
- `check_casks` already covers a hand-written `miru@mpv`.

**3. Pinning.**
- AetherEngine stays at `exactVersion` in project.yml.
- Its FFmpeg (`FFmpegBuild`) is also pinned at `exactVersion`. AetherEngine asks for it with
  `upToNextMinor`, and the app's Package.resolved isn't committed, so it moved from 3.19.2 to
  3.19.3 on its own during the spike.
- Fork both repos to the owner's account and point project.yml at the forks. FFmpegBuild keeps
  its xcframeworks in git, so a fork holds everything a build needs, even if upstream rewrites
  or deletes a tag.

**4. Notices.** AetherEngine is LGPL-3.0 with an App Store / DRM exception (checked at 7.76.0).
That's compatible with our GPL-3.0. Add it and its FFmpeg components to
`THIRD_PARTY_NOTICES.md`.

**5. Rollback rehearsal.** Install a spike build over a dev build and go back; then the reverse.
Check that Stats, downloads, resume points and settings survive both ways. This is when to find
out whether an older build opens a database a newer build migrated.

**Gate to phase 1:**
- The battery comparison shows AetherEngine no worse than mpv: within 10% of mpv's drain on the
  same file. **Met** on 2026-11-27 (2 points against 3 over 25 minutes; above).
- The owner says go.
- The backup can be installed from the steps below on the iPhone, the iPad and the Mac.

**Exit:** nothing to undo. The backup and the pins cost nothing to keep.

## Phase 1: the engine interface (mpv only, no behaviour change)

**The interface.**
- Add `PlayerEngine` in PlayerKit: load, play/pause, seek, rate, volume, tracks (audio,
  subtitles), time and state events, video view, snapshot.
- `MPVController` conforms to it.
- `PlaybackModel`, `PlaybackView`, `ExternalDisplay` and the PiP and AirPlay hand-offs talk to
  the protocol. That's about 170 call sites today, nearly all in `PlaybackModel`.
- The spike's `AetherBridge/AetherPlayerEngine.swift` is the first draft of the protocol.

**Line pauses** move to a "call me at time T" primitive on the engine:
- mpv implements it with its time events, as now;
- AetherEngine will implement it with AVPlayer boundary observers. Its own clock only ticks at
  about 10 Hz, so polling it would land ~100 ms late.

**Gate to phase 2:**
- All Miru unit and UI tests pass on iOS and macOS.
- Pause After Each Line still lands within 0–2 ms of the line's end at 1× and 2×, as in the
  spike lab.
- The owner sees no difference over a week of Dev builds.

**Exit:** keep the refactor (it costs nothing and tidies `PlaybackModel`), or revert the PR.

## Phase 2: AetherEngine as an opt-in second engine

**The switch.**
- Settings ▸ Playback ▸ Engine: **mpv** (default) / **AetherEngine (beta)**.
- The test player and "Don't record playback" from the spike go away; the real player gets both
  engines.

**AetherEngine conforms to `PlayerEngine`:**
- **Native route** (AVPlayer, most files): hosted in AVPlayerViewController for picture in
  picture, AirPlay and Now Playing. The existing hand-offs stay for mpv.
- **Software route** (AetherPlayerView for DTS, TrueHD and other codecs AVPlayer can't play): its
  own picture in picture, and a route picker for audio.
- An **engine info row** in the player's menu (engine, route, codec) and in Advanced ▸ logs, so
  the owner can say what played.

**Gate to phase 3, on the owner's iPhone, iPad and Mac with AetherEngine chosen:**
- **Picture in picture, AirPlay to the TV, external display, background audio and Now Playing**
  work on the native route. Each is a checklist item the owner ticks.
- **Software route:** the device matrix below passes.
- **Speed:** first frame and seeks no slower than mpv on the lab's five test-account files.
  Snapshots for cards work.
- **Battery:** a 30-minute run per engine, same file, within 10%.
- **Stability:** no crash in two weeks of the owner's use.

**Exit:**
- Set the default back to mpv, or hide the setting (one line).
- Removing the conformance and the package is one PR.
- Users never left mpv unless they chose AetherEngine.

## Phase 3: per-file routing, with mpv as the fallback

**The engine is chosen per file, before it opens,** from Jellyfin's `MediaStreams`:

| The file has | Plays with |
| --- | --- |
| Video and audio AVPlayer plays (H.264, HEVC, AV1 where supported; AAC, AC-3, E-AC-3, FLAC, ALAC) | AetherEngine, native route |
| DTS, TrueHD or another codec only the software route plays | AetherEngine software route if phase 2's matrix passed for that codec, else mpv |
| A styled ASS track you've chosen to show (see below) | mpv |
| Anything AetherEngine failed on before (remembered per file) | mpv |

**Runtime fallback:**
- If AetherEngine fails to open, shows no first frame within 8 s, or stalls repeatedly, Miru
  reopens the same file in mpv at the same position.
- It says so in a short note, and remembers the file (by Jellyfin item and media source) so
  the next open goes straight to mpv.

**Manual override:** the player's menu has **Play with mpv** and **Play with AetherEngine**
for the episode, remembered per file. Settings ▸ Playback ▸ Engine stays, as a global "mpv
only".

**Expected share on mpv:** routing by design sends styled ASS to mpv, and the library
measurement (Styled ASS, below) puts that near 40% of anime episodes whenever their English ASS
track is shown. That share is expected, and it isn't counted as a fallback. The log keeps the two
apart: `routed` (the table above sent it to mpv) and `fallback` (AetherEngine was tried and
failed, or the user switched).

**Gate to phase 4:**
- The fallback rate is below 5% of plays over two weeks (logged per play: engine, route, reason).
  Routed plays don't count towards it.
- Every fallback has a known cause.
- The owner's checklist from phase 2 still passes.

**Exit:** set routing to "mpv only" (the existing setting) and ship.

## Phase 4: AetherEngine by default

- New installs and the owner's devices default to per-file routing (phase 3). mpv only plays
  what the routing or a fallback sends it.
- One Dev build cycle of at least two weeks before a release carries it.

**Gate to starting phase 4:** a decision on styled ASS. With routing alone, "AetherEngine by
default" still leaves about 40% of anime on mpv whenever the English track is shown, so the
owner chooses before phase 4 starts:
- build the libass overlay (Styled ASS, step 3) first, and start phase 4 once it passes phase 2's
  checklist with styled tracks; or
- start phase 4 with routing alone, accepting that styled ASS stays on mpv.

**Gate to a release:**
- Phase 3's numbers hold.
- No open `blocks release` issue about playback.
- The owner signs off.

**Exit:**
- Flip the default back to mpv in a follow-up PR.
- Or point the owner at the mpv backup (below) while that's built.

## Phase 5 (optional, decided later): retire mpv

Only if, over at least a month at default:
- the fallback rate is near zero;
- styled ASS is handled without mpv (libass overlay, below);
- the software route covers every codec in the owner's libraries.

**What retiring mpv would involve:**
- `MediaClipper` uses MPVKit's FFmpeg libraries, not mpv. Dropping MPVKit means moving it to
  AetherEngine's FFmpeg (the same FFmpeg API, different module names) or to AVFoundation.
- It removes the hand-offs and the second FFmpeg from the app.

**Exit:** don't do it. Two engines cost app size (the iOS ipa is about 31 MB with mpv's alone);
nothing else forces this phase.

## Styled ASS

**What doesn't change:**
- Miru's Japanese lines are drawn by its own overlay (`TappableLine`) from the subtitle file
  Miru parses itself. They don't depend on the engine's subtitle renderer.
- Jimaku and Kaku subtitles are files Miru loads itself.

**What mpv does today that AetherEngine doesn't** (its cues are plain text, with `\N` turned into
newlines and override tags stripped):
- the English secondary track and sign/song tracks drawn with their fonts, positions and
  karaoke;
- any embedded ASS the owner picks as the visible track.

**Plan:**
1. **Phase 3, routing.** A file whose chosen visible track (the English secondary, or an ASS track
   picked to show) is styled plays with mpv.
   - "Styled" means the track's codec is ASS/SSA and its events use positioning (`\pos`,
     `\move`, `\an` other than the default), drawing or karaoke tags, or more than a few named
     styles.
   - Miru reads the track's header and first events once, then caches the answer per media
     source.
   - Plain ASS (dialogue only) plays fine with AetherEngine.
2. **Measured (2026-11-27), read-only from Jellyfin.** One episode per series was fetched as
   ASS and counted as styled with 6 or more styles, or more than 5% of Dialogue lines carrying
   `\pos`, `\move`, `\an`, drawing, karaoke, `\fad`, `\clip`, `\org`, `\frz` or `\t`:
   - **Library:** of 11,751 anime items, 44% have an English or undefined-language ASS/SSA
     track, 30% have only text (SRT-like) subtitles and 26% have none.
   - **Series:** 137 have an English/undefined ASS track. Of the 101 sampled, 94 (93%) are
     styled, and they hold 95% of the sampled series' episodes.
   - **So:** styled ASS is the norm wherever ASS exists. Routing would send roughly 40% of the
     anime library to mpv whenever that track is shown, which makes step 3 the real question
     for phase 4 (its start gate), not an edge case for phase 5.
   - It's an upper bound for plays: Miru's Japanese lines don't use these tracks, so an episode
     only routes to mpv when its English ASS track is actually shown. Phase 3's log (`routed`)
     gives the real share.
3. **Before phase 4, if the owner chooses it: libass over AVPlayer.** Render the styled track with libass, which MPVKit
   already ships, into a transparent layer above the video, timed by AVPlayer's clock. This is
   how other AVPlayer-based players keep ASS. It's a separate project of 1–2 weeks, decided at
   phase 4's start gate.
4. **Upstream.** Ask AetherEngine for styled ASS events (or the raw packets) through its subtitle
   API. That would make step 3 simpler, but the plan doesn't depend on it.

## Testing the software route (DTS, TrueHD) on a device

The spike's lab ran on the Mac. The owner's device run most likely only used the native route.
Phase 2 adds:

**Test files.**
- On the test account, not the owner's library: one DTS and one TrueHD
  episode (the lab's HEVC 10-bit + TrueHD file, plus a DTS one, since the first DTS file is
  gone).
- Each is also downloaded in Miru, so the run covers a local file as well as a stream.

**A device lab screen.**
- Settings ▸ Advanced ▸ Engine lab, on TestFlight builds only. It runs the spike lab's script
  on the device: open, first frame, 50 seeks, snapshot, 3 s card clip, audio track switch.
- It writes the timings to a log the owner can share from Advanced ▸ logs.
- It runs muted (as every lab run is).

**An owner checklist for the software route**, done by hand once per AetherEngine bump:
- picture in picture starts and stops, and plays on in it for 5 minutes;
- background audio with the screen locked, and resuming from the lock screen;
- an AirPlay audio-only route, with video expected to stay on the device;
- seeks by ±10 s and by scrubbing;
- a 15-minute battery reading against mpv on the same file.

**Gate for routing a codec to the software route:**
- seeks median ≤ 2 s and worst ≤ 4 s (remote DTS was 1.59 / 2.86 s in the lab);
- no missed seeks;
- picture in picture and background audio pass.
- A codec that fails stays on mpv.

## Version pinning

**How it's pinned:**
- project.yml pins only AetherEngine, with `exactVersion`, from the owner's fork, at a tag of
  ours: `<upstream version>-amatsubame.<n>` (now `7.76.0-amatsubame.1`, branch `amatsubame` in
  github.com/zacaronii/AetherEngine).
- That tag's one commit changes only AetherEngine's `Package.swift`: FFmpegBuild comes from the
  owner's fork, and every dependency is `exact:` (FFmpegBuild 3.19.3, LibDovi 2.2.0, SMBClient
  0.3.1, LibTrueHD 3.2.0). Pinning FFmpegBuild in project.yml instead would give SwiftPM two URLs
  for one package, which it warns will become an error.
- A bump is its own PR: merge the upstream tag into the fork's `amatsubame` branch, update the
  pins in `Package.swift`, tag `<version>-amatsubame.1`. Its description has:
  - the upstream changelog between the versions;
  - the Mac lab rerun: ASS cues on the 8-track file, 50 remote DTS seeks, first frame on HEVC
    10-bit + FLAC, snapshot, card clip;
  - the device lab log and the owner's checklist above.
- No automatic updates, and no `upToNextMinor` anywhere in the chain.

**When to bump:**
- Only for a fix we need, a security fix in FFmpeg, or an Xcode/OS change that needs it.
- Not just because a release exists.
- If upstream goes quiet or changes direction, the forks keep building as they are.

## Rollback: going back to the mpv build

**Before AetherEngine reaches users (phases 1–3):** set Settings ▸ Playback ▸ Engine to
**mpv**.

**After phase 4, or if the app itself needs to go back:**
- **iPhone and iPad, within 90 days of the backup:** TestFlight ▸ Miru ▸ Previous Builds ▸ the
  build named in the `mpv-final-<date>` tag ▸ Install.
- **iPhone and iPad, after 90 days:**
  1. Make a branch from the tag. The tag's own `upload-dev.sh` predates `--ios-only`, so commit
     dev's `scripts/upload-dev.sh` and `scripts/homebrew-casks.sh` onto it.
  2. Run `scripts/upload-dev.sh --ios-only Miru`. That makes a new build of the same code with a
     new build number, and leaves the casks alone.
  3. Install it from TestFlight.
- **Mac:**
  1. `brew uninstall --cask miru@dev` (or `miru`)
  2. `brew install --cask zacaronii/amatsubame/miru@mpv`
  - To return: `brew uninstall --cask miru@mpv`, then install `miru@dev` again.
  - Same app, same container, so library, downloads, Stats and settings stay.
- **Data:** all builds share the database. That's why no phase adds a Miru database migration
  that an older build can't open, and why phase 0 rehearses the rollback.

## Effort (rough)

| Phase | Work |
| --- | --- |
| 0 | 1–2 days: tag, backup builds, cask, `--ios-only`, forks, notices, rehearsal |
| 1 | 1 week: protocol, `PlaybackModel` port, line-pause primitive, tests |
| 2 | 1.5–2 weeks: AetherEngine conformance, AVPlayerViewController hosting, software-route PiP, engine info, device lab |
| 3 | 1 week: routing, styled-ASS detection, runtime fallback, per-file memory, logging |
| 4 | days of work, two weeks of use |
| 4a | 1–2 weeks if chosen at phase 4's start gate: libass overlay over AVPlayer |
| 5 | not planned |

Phases 1–3 take about 3–4 weeks, the same as the spike's estimate. The two-week gates add time,
not work.

## Open questions

- **More forks:** LibDovi and LibTrueHD are binary packages from AetherEngine's author, like
  FFmpegBuild, and SMBClient is a third party's. They're pinned exactly but not forked, so upstream
  could still delete a tag. Forking them would make the build fully independent of upstream.
- **Battery:** answered for phase 0 (AetherEngine level with mpv or slightly better; above). Still
  open: how much the software route costs, which phase 2's device testing measures per codec.
- **Mac:** AetherEngine's AVPlayer route on macOS hasn't been run outside the lab. Phase 2's
  checklist covers it. If the Mac lags, routing can keep the Mac on mpv longer than iOS.
- **iPad external display and Stage Manager** with AVPlayerViewController: untested.
- **Styled ASS:** measured (above): 93% of sampled series with English ASS are styled, about 40%
  of the anime library. Still open: how often the owner actually shows that track (phase 3's
  `routed` log), and whether to build the libass overlay before phase 4.
