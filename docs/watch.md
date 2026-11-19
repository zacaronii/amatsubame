# Kiku on Apple Watch

The iPhone is the brain: Kiku keeps playing on the phone, and the watch is a screen and a button.
The watch app talks to no server (no Audiobookshelf, dictionary or Anki), only to Kiku on the
iPhone through WatchConnectivity. Playing on the watch by itself is planned in
[KIKU_PLAN.md](KIKU_PLAN.md) (milestones 2–5); until then this is the whole design.

## Pieces

| Piece | Where | What it does |
| --- | --- | --- |
| `KikuWatchLink` | `Packages/KikuWatchLink` | The Codable messages both sides use (`WatchNowPlaying`, `WatchState`, `WatchCommand`, `WatchReply`, `WatchQueuedMark`, and Live Text's `WatchTranscript`, `WatchTranscriptPart`, `WatchLookup`), how they're packed into WatchConnectivity dictionaries (`WatchMessages`), the position worked out from a sample, `LineFollow` (which line is playing, shared with Kiku's `TranscriptFollow`), `WatchStateStore` (what the complication reads) and `WatchTranscriptStore` (the watch's last five transcripts). Tested with `swift test`. |
| `WatchBridge` | `Kiku/Watch` (iOS only) | The phone's side: sends the state, answers the watch (buttons, Live Text's transcript, lookups, cards). Started in `KikuApp.init`, since the watch can wake Kiku with no window. |
| `KikuWatch` | `KikuWatch/` | The watch app (watchOS 26, `$(BUNDLE_ID_PREFIX).kiku.watchkitapp`), embedded in Kiku's iOS app (Embed Watch Content). |
| `KikuWatchWidgets` | `KikuWatchWidgets/` | The complication and Smart Stack widget, embedded in the watch app. |

## State: no per-second traffic

- The phone sends `WatchState` (title, show or author, chapter, a ≤100 px JPEG cover, position, duration, rate, play state, skip intervals and when the position was sampled) with `updateApplicationContext`.
- `WatchBridge` follows the player through Observation, but only sends what the watch couldn't predict (`WatchNowPlaying.predicts`): a play or pause, a seek or skip, a new speed, chapter or episode, or a drift of more than 1.5 s. Plain playing sends nothing.
- The watch works out the position from `sampledAt` and the rate (`position(at:)`), and redraws once a second with a `TimelineView` (slower with the wrist down).

## Buttons

- `sendMessage` with a `WatchCommand`: play/pause, skip back/forward (the phone's intervals), mark. The reply carries the new state, and for a mark "Marked 0:52".
- **Mark** uses `KikuEnvironment.mark(.watch)` (a new `AudioMark.Source`), plus `MarkChime` when the phone plays to headphones (never out loud through the speaker). The watch shows "Marked 0:52 · Mine it later in Marks on your iPhone." with a success haptic.
- **Phone out of reach:** a mark is queued with `transferUserInfo` as a `WatchQueuedMark` (the episode and the position the watch worked out), so it marks the right moment when it arrives, even if the phone has moved on: "Will mark when your iPhone is near." The other buttons say "Your iPhone is out of reach" under the controls for a moment. No alerts.
- **The crown** turns the iPhone's volume: `WKInterfaceVolumeControl(origin: .companion)` in the header.

## Screens

1. **Now Playing:** cover, title, chapter (or show), progress with elapsed and remaining time, skip back / play-pause / skip forward (each a third of the width, 40 pt high), and a large Mark button in Kiku orange. With Live Text on, a button at the top left opens it (the header moves down 10 pt to clear it).
2. **Marked / Card added:** a card over the screen that goes after 2.5 s (an overlay: a sheet presented from here never showed).
3. **Nothing playing:** the glyph and "Start something in Kiku on your iPhone".
4. **Live Text:** below.

## Complication and Smart Stack

- The glyph is the face-on bird with headphones (`Design/icons/Kiku/Kiku-glyph-front.svg`), a template vector in `KikuWatch/Glyph.xcassets`, rendered with `.widgetAccentable()` so the face tints it.
- **Corner:** the glyph, with the progress as the corner gauge (`widgetLabel`). **Circular:** the glyph in a progress ring. Nothing playing: only the glyph.
- **Rectangular (Smart Stack):** "KIKU", the title, the chapter (or show) and progress. It has **no Mark button**: a widget's button runs its intent in the widget extension, which can't use WatchConnectivity to reach the phone. A tap opens the app, whose Mark is one tap away.
- **Timeline:** the watch app saves the state with `WatchStateStore` (the App Group `group.com.amatsubame`; without it, the complication shows only the glyph) and reloads the timeline only when the episode, play state, chapter or position changes. While playing, the timeline has four entries five minutes apart, so the gauge moves without one entry a second.

## Signing

The watch app and widget use the App Group entitlements the other targets use (`Shared/SharedSetup.entitlements` in the simulator, `AMATSUBAME_DEVICE_ENTITLEMENTS` on devices). Automatic signing registers their App IDs (`…kiku.watchkitapp`, `…kiku.watchkitapp.widgets`) the first time it signs them. `scripts/upload-dev.sh` archives Kiku for iOS with the watch app inside.

## Testing

- `swift test` in `Packages/KikuWatchLink`: message round trips, the worked-out position (time, rate, pause, the end), what counts as news, keys, and clock text.
- `swift test` also covers Live Text: the line followed from the worked-out position, transcripts split into parts that fit a message and put together again, the watch's store, and the new commands and replies.
- By hand: the `KikuWatch` scheme in a watch simulator paired with an iPhone simulator running Kiku. WatchConnectivity works between paired simulators (messages and context; not `transferFile`). Install the watch app and open it before launching Kiku, or Kiku sees no watch app. Launch Kiku with `UITEST_KIKU=1 UITEST_KIKU_PLAYER=1` for an episode with a transcript, plus `UITEST_KIKU_LIVE_TEXT=1` to turn Live Text on and `UITEST_DICTIONARY_ZIPS` for lookups.

## Live Text

The transcript on the watch, so you can mine on the go. Off by default: Kiku ▸ Settings ▸ Playback ▸ "Live Text on Apple Watch" (`ListenSettings.watchLiveText`, Core migration `v40_watch_live_text`; the toggle calls `WatchBridge.setLiveText`). Off, no transcript leaves the phone.

- **Getting the transcript:** with Live Text on and the player showing a transcript, `WatchNowPlaying.transcript` names it (`<key>#<Kaku fingerprint>`). A watch without that transcript asks for it with `transcriptPart(id:from:)`, and the phone answers in parts of about 40 KB of lines (`WatchTranscript.part`, under WatchConnectivity's 64 KB message limit; `WatchTranscriptAssembly` puts them together). Lines carry position, start, end and text (`TappableLine.sentence`, so character indices match the phone's lookup); no word timings. The watch keeps the last five on disk (`WatchTranscriptStore`).
  - Why messages, not `transferFile` as first planned: the watch simulator never hands transferred files to the app (`handleIncomingFile` is logged, the delegate isn't called), so it couldn't be tested; and Live Text needs the phone reachable for lookups anyway. A transcript of a long episode is a few parts.
- **Following:** no extra traffic. The watch works the position out from the v1 state and finds the line with `LineFollow` (the same as the player's `TranscriptFollow.index`); a drift over 1.5 s already makes the phone send a fresh state.
- **Screen:** the earlier lines (up to 150) dimmed at 13 pt, the line playing at 20 pt, and under it one row with its time and a small **Mark Line** pill (so the transcript keeps the screen). Lines after it aren't shown. A `TimelineView` redraws twice a second while playing, once a minute with the wrist down (`isLuminanceReduced`: text dimmed, no scroll animation); on wrist raise it jumps to the line playing.
- **Crown:** scrolling (`onScrollPhaseChange` → interacting) leaves follow mode. Tapping an earlier line chooses it: it grows, with **Mark** and **Replay**. **Back to now** follows again.
- **Words:** the focused line is a flow of per-character views (SwiftUI's `Text` doesn't report which character was tapped). A tap sends `lookUp(key:line:character:)`; the phone runs the transcript's lookup (`LookupService.lookup(text:utf16Offset:showSource:)`, so it's counted and kept in history; like a tap on the phone it pauses the episode, and `endLookup` (closing the card, or adding the card) plays it again unless you pressed play or pause meanwhile) and answers with a `WatchLookup`: the matched range (highlighted), headword, reading, the first compact-summary meaning, the first frequency, the lookup count and whether it's mined.
- **Add card:** `addCard` mines the first result on the phone with `MiningService.mine` and the player's `miningContext(for:)` (the line's audio and the cover), through the outbox, so it works with Anki unreachable. The watch shows "Card added · 雨 · <deck>".
- **Mark Line:** a mark at the line's start with source `watchLine` (no migration: the source is text). Marks treats it like the player's button (`guessesEarlier: false`), so it shows that line, not the one before. Out of reach, it's queued like Mark with `WatchQueuedMark.wholeLine`.
- **Replay:** the line's clip through the player's clip path (`PlaybackModel.playClip`); the episode pauses for it and plays again when the clip ends.
- Lines are named by episode key and position; if the phone has moved to another episode, it says so instead of acting on the wrong line.
