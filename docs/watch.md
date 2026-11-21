# Kiku on Apple Watch

The iPhone is the brain: Kiku keeps playing on the phone, and the watch is a screen and a button.
The watch app talks to Kiku on the iPhone through WatchConnectivity, and to no server, with one
exception: it downloads the episodes and books sent to it straight from Audiobookshelf (On the
watch, below). Playing on the watch by itself is planned in [KIKU_PLAN.md](KIKU_PLAN.md)
(milestones 2–5).

## Pieces

| Piece | Where | What it does |
| --- | --- | --- |
| `KikuWatchLink` | `Packages/KikuWatchLink` | The Codable messages both sides use (`WatchNowPlaying`, `WatchState`, `WatchCommand`, `WatchReply`, `WatchQueuedMark`, and Live Text's `WatchTranscript`, `WatchTranscriptPart`, `WatchLookup`), how they're packed into WatchConnectivity dictionaries (`WatchMessages`), the position worked out from a sample, `LineFollow` (which line is playing, shared with Kiku's `TranscriptFollow`), `WatchStateStore` (what the complication reads) and `WatchTranscriptStore` (the watch's last five transcripts). Tested with `swift test`. |
| `WatchBridge` | `Kiku/Watch` (iOS only) | The phone's side: sends the state, answers the watch (buttons, Live Text's transcript, lookups, cards). Started in `KikuApp.init`, since the watch can wake Kiku with no window. |
| `WatchLibraryModel` | `Kiku/Watch` (iOS only) | What's sent to the watch (Core's `KikuWatchItemStore`, migration `v44_kiku_watch_items`), the watch's token, and the watch's last report. Send to Watch and Storage's On Apple Watch are in `WatchLibraryViews.swift`. |
| `WatchDownloads` | `KikuWatch/` | The watch's side of that: background downloads, the files, On This Watch. |
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

## On the watch (milestone 2, #126)

- **Sending:** Send to Watch (an episode's long press, a book's page, the player's ⋯) adds a `WatchItem` (one audio file: item, episode, `ino`, extension, title, subtitle, length, size, chapters) to `WatchLibraryModel`. Single-file books only, as Kiku plays. The buttons show only with a paired watch that has Kiku (`isWatchAppInstalled`).
- **The list travels in the context:** the phone's application context carries `WatchLibrary` (every item, and a `WatchAccess` while there's anything on it) beside the state, both every time (a context replaces the last whole). The watch downloads what's missing, deletes files whose items left the list, and keeps the token in its Keychain (`WatchKeychain`). Removing on the watch deletes the file and sends `removedFromWatch` with `transferUserInfo`; the watch keeps it off until the phone's list drops it.
- **The token:** Audiobookshelf's access tokens last an hour, and watchOS starts a background download when it chooses (often later, on the charger). So for an admin account the phone creates an API key of its own, "Kiku on Apple Watch" (`POST /api/api-keys`, no expiry; admins only, others get 403), stored in the phone's Keychain and revoked (`DELETE /api/api-keys/:id`, authorized by the key itself) when you sign out or change accounts. Other accounts hand over the phone's access token; before starting downloads the watch asks for a fresh one (`WatchCommand.freshAccess`), and a 401 is retried once with a fresh token. Signed in with your own API key, that key goes (it doesn't run out either).
- **Downloads:** `WatchDownloads` uses a background `URLSession` (`com.amatsubame.kiku.watch.downloads`); `KikuWatchAppDelegate` passes the session's background wake-ups to it. Files go to Application Support/Audio as `WatchItem.fileName`; one that's there is ready. Without a usable token an item waits ("Waiting for your iPhone") and starts when the phone is reachable again.
- **Send Now** (#129): for a server the watch can't reach, Storage's row offers Send from iPhone when the phone has the item downloaded. The phone marks the item `fromPhone` (the watch cancels its own download and shows "Coming from your iPhone"), links its file into Caches/WatchTransfers and sends it with `transferFile`, metadata `watchFile: <key>`. The watch moves it out of the inbox in `session(_:didReceive:)` to Audio/Incoming (it can arrive before the list) and `reconcile` puts it in place. Completion isn't always reported, so `WatchBridge.followTransfers` reads `outstandingFileTransfers` every second for the row's %, and a ready item in the inventory cancels what's still going. A failed send turns `fromPhone` off again, so the watch goes back to downloading it itself.
- **Waking up:** watchOS delivers the phone's context by waking the watch app in the background (`WKWatchConnectivityRefreshBackgroundTask`); `KikuWatchAppDelegate` starts the session and holds the task until `hasContentPending` is false, so a list sent from the phone starts its downloads without opening the app. watchOS rarely wakes the app for a context alone (on a real watch it waited until Kiku was opened), so when something is added (and on the phone's Sync Now) `WatchBridge.wakeWatch` also sends the context with `transferCurrentComplicationUserInfo`, which wakes the app right away, when Kiku's complication is on the active face (`isComplicationEnabled`; 50 a day); the watch takes the list from `didReceiveUserInfo`. Without the complication the phone's list says so. Small items (under 50 MB) get a high task priority, so an episode isn't stuck behind a book.
- **Progress while suspended:** a background session delivers no progress while the app is suspended, so the phone's figure is the watch's last report; reopening the watch app reads each task's bytes and reports at once, and the phone says how old a figure is after two minutes. With the phone near, watchOS routes the watch's traffic through it over Bluetooth (slow for a book).
- **Reporting back:** the watch's own application context carries `WatchInventory` (each item's state: waiting, downloading with bytes, ready with its size, failed with why; and free space), sent when a state changes, progress crosses 10 % or free space moves 50 MB. The phone shows it in Settings ▸ Storage ▸ Downloads ▸ On Apple Watch (swipe to remove); the watch shows it in On This Watch (the watch button at the top right of Now Playing), with Remove and Retry.
- **Checked** between the paired test simulators with a non-admin account: a 5 MB episode sent from the phone arrived on the watch within seconds. `KIKU_SEND_TO_WATCH=<item>/<episode>` (Debug) sends one at launch.

## Playing on the watch (milestone 2, #127)

- **Modes:** `WatchSession.mode` is `.phone` (the remote, as before) or `.watch` (this watch's own player), kept in the watch's defaults. The top-right toolbar button shows which (an iPhone or a watch glyph) and opens Play On (iPhone / This Watch) above On This Watch; tapping a ready item there plays it on the watch and switches to Watch mode (pausing the phone first if it was playing). Choosing iPhone pauses the watch.
- **Now Playing** draws both modes alike: `WatchPlayer.nowPlaying` is a `WatchNowPlaying`, so the controls, progress and Mark are the same views. In Watch mode the buttons act on the watch (`WatchSession.performHere`), the crown turns the watch's volume (`WKInterfaceVolumeControl(origin: .local)`), and Live Text is hidden (it follows the phone's player; milestone 5). Mark is queued for the phone as a `WatchQueuedMark` at the watch's position, as an out-of-reach mark is.
- **Player:** `WatchPlayer` (AVPlayer on the local file) activates an `AVAudioSession` with `.playback`, `.spokenAudio` and `.longFormAudio`, so watchOS routes to headphones and asks for them when none are connected (no speaker playback yet; open question 4). Now Playing info and the remote commands (play, pause, toggle, skip back and forward at the phone's intervals) are set up once. The watch app's Info.plist (`KikuWatch/Info.plist`, generated by XcodeGen and merged with the generated keys) has `UIBackgroundModes: audio`.
- **Places:** `WatchPlaces` keeps each item's position here with when it was saved (every 5 s while playing, on pause, skip and stop; finished at the end). The phone's list carries its own place per item (`WatchLibrary.places`: the newer of the phone's and Audiobookshelf's), which the watch adopts only when it's newer than its own. Milestone 3 sends the watch's places and listening back.
- **Checked** on the paired test simulators: an episode sent to the watch played there in Watch mode. `KIKU_WATCH_PLAY=<item>/<episode>` (Debug, the watch app) plays one once it's downloaded.

## Listening back to the phone (milestone 3, #128)

- **On the watch:** `WatchListeningLog` (in `WatchPlayer`) keeps stretches of listening (`WatchListening`: item, start and end position, seconds of real playback at any speed, rate, start and end time, finished), one per item until a pause over five minutes, like the phone's Stats. `WatchPlayer` counts playback every 5 s, before a skip or a speed change, and on pause, stop and the end (gaps over a minute aren't trusted). The pending stretches are kept in the watch's defaults until acknowledged.
- **Sending:** on pause, stop, the end, the phone coming into reach and Sync Now, every pending stretch goes at once: with `sendMessage` when the phone is reachable (its reply acknowledges), else `transferUserInfo` (older queued copies are cancelled first). The phone's context also carries `WatchLibrary.acknowledged` (id → the `endedAt` it has, the latest 300), so a stretch is dropped once the phone has that version; one that grew since stays.
- **On the phone:** `WatchLibraryModel.apply` treats them as listening done here: Stats (`ActivityLog.record` at the stretch's end, only the seconds new since the version applied before: Core `kikuWatchListening`, migration `v45_kiku_watch_listening`), an Audiobookshelf session with the watch's id (so it's upserted) from the device "Kiku on Apple Watch" (`<phone's device id>-watch`), and the place: queued as progress (`reportedAt` = the stretch's end) and shown in the library, unless this phone or Audiobookshelf has a newer one, or the phone is playing that item. The phone's own `listenProgress` isn't written, so it can still ask.
- **Never back silently:** `PlaybackModel.resumeChoice` — when the newest place (Audiobookshelf's, which the watch's listening set) is more than a minute behind this phone's own last place, the player loads at the newer one paused and asks "Where to continue?" with both (the newer one named Apple Watch when the watch's listening set it).
- **Visible sync:** the watch's On This Watch has Sync Now and "Synced 2 min ago" (or how many sessions are waiting for the iPhone); the phone's On Apple Watch has Sync Now (sends the list, places and acknowledgements again) and when listening from the watch last arrived. Marks made in Watch mode go as `WatchQueuedMark`s, as before.
- **Checked** on the paired test simulators (the phone holding progress with `DEV_HOLD_PROGRESS`'s marker): 12.6 s played on the watch reached the phone's Stats with a session and a progress job, and the watch's queue emptied with its acknowledgement. `KIKU_WATCH_PLAY_FOR=<seconds>` (Debug) pauses after that long.

## Automatic rules (milestone 4)

- **Settings:** Core's `KikuWatchRules` (one row: onceStarted, ahead 0–5, removesPlayed, keepsManual, storageLimit in bytes), shown in Settings ▸ Downloads ▸ Apple Watch when the watch has Kiku.
- **Reasons:** `WatchItem.reason` is nil for one sent by hand, `.started` or `.ahead` for a rule's; On Apple Watch rows say By hand / Started / Ahead.
- **Once Started:** `AudioAutoDownloadManager.startedPlaying` calls `WatchLibraryModel.startedPlaying`, which adds it unless it's declined or doesn't fit the limit.
- **Download ahead and Remove Played:** `AudioAutoDownloadManager.run` hands each covered show's download ahead list (most recently played show first) and the shows it judged to `WatchLibraryModel.applyRules`; `WatchRulesPlanner` (pure, `WatchRulesPlannerTests`) works out what to add and remove. A show whose episodes couldn't be fetched keeps its items; offline nothing moves; a started, unfinished episode isn't removed for dropping out of the list. The storage limit counts the whole list and stops download ahead at the first episode that doesn't fit (said under the settings).
- **Declined:** removing an automatic item (on the phone or the watch) puts its key in `kikuWatchDeclined`, so the rules don't add it again; sending it by hand clears that.
- Additions go in one list update, so a run spends one complication wake-up.

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
- Lines are named by episode key and position. A command about an episode the phone isn't playing (`WatchCommand.lineKey`) is answered from its saved transcript (`WatchBridge.performSaved`): marks, lookups, cards (with the episode's own audio, found as Marks does) and transcript parts; nothing there pauses or plays the phone.

### Without the phone (milestone 5)

- **Transcripts travel with the items:** with Live Text on, each list item carries its saved transcript's id (`WatchItem.transcript`, named as the playing one is). Sending an item fetches its transcript from Kaku if the phone hasn't it, then sends the list again. The watch fetches each missing one in parts while the phone is reachable (`WatchSession.prefetchTranscripts`, one at a time, after the list arrives, after each transcript and when the phone comes back); one the phone can't send isn't asked for again that launch. `WatchTranscriptStore` keeps every item's transcript plus the last five others.
- **Watch mode:** Live Text follows the watch's player (`WatchPlayer.nowPlaying.transcript`). Mark Line queues a whole-line mark (`transferUserInfo`); Replay plays the line on the watch and goes back (`WatchPlayer.replay(from:to:)`, a boundary time observer); a lookup goes to the phone while the watch's player pauses (and plays again on close).
- **Out of reach:** a tapped word does nothing, in either mode (it used to mark its line, which the owner found surprising: Mark Line does that on purpose).
- Debug: `KIKU_WATCH_OPEN_LIVE_TEXT=1` opens Live Text at launch (with `KIKU_WATCH_PLAY`), and the phone's `KIKU_WATCH_LIVE_TEXT=1` turns Live Text on.
