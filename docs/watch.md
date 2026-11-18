# Kiku on Apple Watch

The iPhone is the brain: Kiku keeps playing on the phone, and the watch is a screen and a button.
The watch app talks to no server (no Audiobookshelf, dictionary or Anki), only to Kiku on the
iPhone through WatchConnectivity. Playing on the watch by itself is out of scope.

## Pieces

| Piece | Where | What it does |
| --- | --- | --- |
| `KikuWatchLink` | `Packages/KikuWatchLink` | The Codable messages both sides use (`WatchNowPlaying`, `WatchState`, `WatchCommand`, `WatchReply`, `WatchQueuedMark`), how they're packed into WatchConnectivity dictionaries (`WatchMessages`), the position worked out from a sample, and `WatchStateStore` (what the complication reads). Tested with `swift test`. |
| `WatchBridge` | `Kiku/Watch` (iOS only) | The phone's side: sends the state, carries out the watch's buttons. Started in `KikuApp.init`, since the watch can wake Kiku with no window. |
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

1. **Now Playing:** cover, title, chapter (or show), progress with elapsed and remaining time, skip back / play-pause / skip forward, and a large Mark button in Kiku orange.
2. **Marked:** a sheet that closes itself after 2.5 s.
3. **Nothing playing:** the glyph and "Start something in Kiku on your iPhone".

## Complication and Smart Stack

- The glyph is the face-on bird with headphones (`Design/icons/Kiku/Kiku-glyph-front.svg`), a template vector in `KikuWatch/Glyph.xcassets`, rendered with `.widgetAccentable()` so the face tints it.
- **Corner:** the glyph, with the progress as the corner gauge (`widgetLabel`). **Circular:** the glyph in a progress ring. Nothing playing: only the glyph.
- **Rectangular (Smart Stack):** "KIKU", the title, the chapter (or show) and progress. It has **no Mark button**: a widget's button runs its intent in the widget extension, which can't use WatchConnectivity to reach the phone. A tap opens the app, whose Mark is one tap away.
- **Timeline:** the watch app saves the state with `WatchStateStore` (the App Group `group.com.amatsubame`; without it, the complication shows only the glyph) and reloads the timeline only when the episode, play state, chapter or position changes. While playing, the timeline has four entries five minutes apart, so the gauge moves without one entry a second.

## Signing

The watch app and widget use the App Group entitlements the other targets use (`Shared/SharedSetup.entitlements` in the simulator, `AMATSUBAME_DEVICE_ENTITLEMENTS` on devices). Automatic signing registers their App IDs (`…kiku.watchkitapp`, `…kiku.watchkitapp.widgets`) the first time it signs them. `scripts/upload-dev.sh` archives Kiku for iOS with the watch app inside.

## Testing

- `swift test` in `Packages/KikuWatchLink`: message round trips, the worked-out position (time, rate, pause, the end), what counts as news, keys, and clock text.
- By hand: the `KikuWatch` scheme in a watch simulator paired with an iPhone simulator running Kiku. WatchConnectivity works between paired simulators.

## Later: Live Text (v2)

An optional transcript feed on the watch (behind a Settings toggle, off by default): the phone sends an item's sentences once with `transferFile`, and the watch follows the current line from the same state messages. Not built yet.
