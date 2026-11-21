# Kiku: automatic downloads and playing on the watch

The plan for Kiku's next big update. It builds on a survey of other podcast and audiobook watch apps (Nov 2026;
summary at the end). It changes docs/watch.md's scope: the watch can now play by itself. Milestones 1–3 are built
(#111–#114, #126–#128); docs/watch.md describes what was built.

## Principles

- **The phone stays in charge.** It's the only one that writes to a server: the watch's
  progress, listening time and marks go back to it, and through its outbox to Audiobookshelf.
  The watch reads from Audiobookshelf only to download audio, using a token the phone hands it.
  It never talks to Kaku, Anki or a dictionary.
- **Downloads only, no streaming on the watch** (as Plappa 2.0 decided). Streaming on the watch
  uses a lot of battery, and it fails when the Wi-Fi drops.
- **Nothing is hidden.** Every download says why it's there (by hand, download ahead, started),
  and every item on its way to the watch shows its state: waiting for the charger, 40%, failed
  with Retry. The phone and the watch both list what's on the watch, each with a Remove button.
  This matches the downloads rule: nothing downloads unless a rule you turned on asks for it.
- **The watch has two modes,** and the screen always shows which one is on. On iPhone it's the
  remote it is today; On Watch plays the watch's own downloads.

## Milestone 1: automatic downloads on the phone

This milestone is phone only, and the watch's rules later build on it. It works like Yomu's
`AutoDownloadManager`: a rule per library, run at launch, on returning to the app, when a
player closes and when settings change.

- **Download ahead (podcast libraries):** keep N episodes downloaded for each show you follow
  (0 turns it off). Two orders:
  - **Newest:** the latest N episodes, the usual choice for news shows.
  - **In order:** the next N unplayed after the one you're on, for serial shows and lessons.
  - A show can override its library's setting.
- **Download once started** (a toggle for podcasts and books): starting an episode or book
  downloads it, so a stream that drops picks up from the file.
- **Remove played downloads:** one day after an episode finishes (or a book is marked finished),
  its download goes. Off by default.
- **Keep downloads you made by hand:** a toggle, on by default. While it's on, a download you
  started yourself is never removed by the rules above. Turned off, those count as played
  downloads too.
- **Pause for shows you've stopped playing:** download ahead pauses for a show you haven't played
  in 15+ days (Apple Podcasts does this). The show's row shows it's paused, and playing the show
  starts it again.
- **Storage screen:** Settings ▸ Storage gives each download's reason (By hand / Ahead / Started)
  and the total. The existing cellular rows apply.
- **Core:** an `AudioAutoDownloadSetting` table (library, ahead, order, onceStarted,
  removesPlayed, keepsManual) and the reason column on downloads, in a new migration. The
  planner is a pure function with unit tests, as `AutoDownloadPlanner` is.

## Milestone 2: playing on the watch

- **Sending:** Send to Watch, on an episode or book page and in the player's ⋯ menu. The phone
  passes the watch an Audiobookshelf token and the download's URL over WatchConnectivity. The
  watch downloads it with a background `URLSession`.
  - When Audiobookshelf is reachable from the internet, the watch can download over its own
    Wi-Fi or LTE and doesn't need the phone. A server only on a VPN (the watch has no Tailscale)
    or a home network can only be reached from the watch on that Wi-Fi.
  - watchOS chooses when downloads run, most readily on the charger.
  - **Send Now** is a fallback: the phone sends its own downloaded file (`transferFile`), for a
    server the watch can't reach. It's slower and has a known bug where completion isn't
    reported, so progress is followed from the transfer itself. Built (#129): Send from iPhone on
    Storage's On Apple Watch rows.
- **Long books:** a book only goes to the watch in part, the next few hours. Books split into
  several files send files. A single-file `.m4b` would be cut on the phone with
  `AVAssetExportSession`, which is already used for clips. The part is topped up as you listen.
  Dropped for now (#129, 2026-11-20): the watch downloads whole books straight from
  Audiobookshelf, has room for them, and cut parts would have to go through the phone.
- **Player on the watch:** an `AVAudioSession` set to `.playback`, `.spokenAudio` and
  `.longFormAudio`, so the system picker asks for headphones. Then Now Playing and the remote
  commands, skip intervals, speed and chapters.
  - **Speaker:** no speaker playback in this milestone. Apple's documentation contradicts
    itself here, so it's checked on the real watch later.
- **Modes:** an iPhone / Watch switch at the top of Now Playing, with a badge: a phone or watch
  glyph. On Watch has its own list, On This Watch, with each item's state and size, plus
  storage free.
- **Credentials:** the phone hands the token over once and again when it changes. Signing out on
  the phone removes it from the watch's Keychain.
- **Testing:**
  - In the watch simulator, the direct download works, but `transferFile` doesn't arrive.
  - The real watch is needed for speed, the charger, Bluetooth and Send Now.

## Milestone 3: progress and marks back to the phone

- **What the watch records:** every listening session (episode, start and end position,
  times, speed) and every mark, kept in order. They go back with `transferUserInfo`, plus
  `sendMessage` when the phone is reachable.
- **On the phone:** it applies them and acknowledges them, and the watch drops them only after
  that. It sends progress, listening time (Stats) and marks through the outbox, as if the
  listening had happened on the phone.
- **Conflicts:** the latest timestamp wins, compared with Audiobookshelf's `lastUpdate`. A move
  backwards of more than a minute asks first ("Continue from 12:40 (watch) or 18:02 (iPhone)?").
  It never jumps back silently.
- **Visible sync:** "Last synced 2 min ago" and a **Sync Now** button on both sides (Overcast's
  most-thanked addition).

## Milestone 4: automatic rules for the watch

They're built from milestone 1's lists. While the watch is on its charger, watchOS fills it.
- **Sync to Watch Once Started:** what you start on the phone also goes to the watch (Apple
  Books' "current book" rule).
- **Watch download ahead:** the first N episodes of download ahead (or of In Progress) are
  kept on the watch. N is 1 to 5, default 3.
- **Remove from the watch** once played, and when a rule no longer includes an item. With "Keep
  downloads you made by hand" on, an item you sent by hand stays.
- **Storage limit for the watch** (for example 2 GB). The rules stop at it and say so.
- Built (2026-11-20): Settings ▸ Downloads ▸ Apple Watch. Download ahead takes the first N of
  each show's download ahead list (In Progress isn't a source yet). Remove Played waits a day,
  as on the phone. An automatic item you remove stays off.

## Milestone 5: Live Text without the phone

- The transcript and chapters travel with each download, saved as the transcript already is
  (`WatchTranscriptStore`, which will keep a file for every item on the watch, not just the last
  five).
- In On Watch mode, Live Text follows the watch's own player. Mark Line, choosing a line and
  Replay all work on the watch.
- **Lookups:** when the phone can be reached, they go to it, as they do today, even in On
  Watch. When it can't, a tapped word does nothing (built first as marking its line; the owner
  found that surprising, so Mark Line is the way to keep one for Marks). No dictionary on the watch.
- **Kaku isn't involved.** Transcripts come from the phone, which has them cached, so a Kaku
  behind a VPN is fine.
- Built (2026-11-21): transcripts go as messages in parts while the phone is near (not with the
  download: `transferFile` can't be tested in the simulator, and parts already work). Sending an
  item fetches its transcript from Kaku first if the phone hasn't it.

## Milestone 6: polish

- What's left from 0.3.0:
  - Siri "Mark this in Kiku" in the car.
  - What Replay should do: play the clip then resume, or rewind.
  - Whether the 20 pt line size is right.
  - The Live Text checks still untested by hand: crown scroll, choosing a line, Back to now,
    Always On.
- The complication and the Smart Stack show the watch's own playback in On Watch mode.
- Chapters on the watch (previous or next chapter, and a list) for both modes.
- Speed control on the watch.
- Other Kiku polish found while using it. Each item becomes its own issue.

## Order and releases

- **Milestone 1** goes first, on its own (phone only). It could ship in a 0.4.0 before the
  watch work.
- **Milestones 2 and 3** ship together, because playing on the watch without progress going back
  would lose your place.
- **Milestones 4 and 5** follow.
- **Milestone 6** runs alongside, as issues.
- Each milestone gets its own issues and PRs into dev, as usual.

## Open questions (answered by testing)

1. Can the watch reach Kaku through the iPhone's Tailscale while the phone is near? This only
   matters if the watch ever asks Kaku for anything; the plan doesn't need it.
2. ~~Which Audiobookshelf token the watch gets.~~ Answered (#126): an admin's watch gets an API
   key of its own, revoked on sign-out; anyone else's gets the phone's access token (an hour) and
   asks for a fresh one before downloading. API keys are admin-only in 2.36.
3. How fast watch downloads really are on Wi-Fi, on the charger and through the phone.
4. Whether `.longFormAudio` can play through the watch speaker on watchOS 26/27.
5. Whether a part of a single-file `.m4b` cut on the phone keeps its chapters and timings
   lined up, so the watch's positions map back to the whole book.

## What other apps do (survey summary)

- **Playing on the watch:** every podcast or audiobook watch app with real users now plays its
  own downloads on the watch. Most keep a phone-remote mode beside it; Pocket Casts shows the
  active one as a P or W badge. Libby and ShelfPlayer have no watch app.
- **Getting audio there:** most moved from phone-to-watch transfer to the watch downloading by
  itself with credentials from the phone. Overcast switched in 2020 and Audible in 2022;
  BookPlayer never shipped phone transfer. Apple recommends a background `URLSession` for
  large downloads.
- **Automatic rules:** they're built from a list the phone already has plus a small count
  (Apple Podcasts: Up Next and Saved; Overcast: a playlist, 20 episodes; Pocket Casts: the
  first 3–10 of Up Next; Apple Books: the current book, 5 hours of it). They're filled while
  the watch charges.
- **What fails:**
  - The most common complaint is sync you can't see.
  - Progress is lost or overwritten (Castro, Spotify, early Overcast).
  - Long files fail to transfer.
  - The designs that hold up use timestamped sessions that the phone or server acknowledges
    (Pocket Casts, Prologue, AudioBooth).
- **Transcripts:** none of the surveyed apps shows a transcript on the watch.
