# Media credits

The README's images show the apps with content that may be shown publicly. Nothing comes from anyone's
private library or servers.

| File | Shows | Content and licence |
| --- | --- | --- |
| `banner.png`, `*-icon.png` | the swift and the app icons | Amatsubame's own artwork (GPL-3.0, like the repository); the banner's 「もう一話だけ…」 is drawn from the outlines of [M PLUS Rounded 1c](https://fonts.google.com/specimen/M+PLUS+Rounded+1c) ExtraBold (SIL Open Font License 1.1) |
| `yomu-1-home.png` | Yomu's Library on the demo Kavita | the demo servers' books and manga: [CREDITS.md](../../CREDITS.md) (Aozora Bunko, public domain; *Pepper&Carrot*, CC BY 4.0) |
| `yomu-2-lookup.png` | Yomu: a speech bubble zoomed in, and the lookup of 出来上がり | *Pepper&Carrot* episode 1 in Japanese by David Revoy, [peppercarrot.com](https://www.peppercarrot.com), CC BY 4.0 |
| `miru-1-home.png` | Miru's Watch home on the demo Jellyfin | *Sintel* and *Tears of Steel* © Blender Foundation, CC BY 3.0; 時を超えた迷信 (Terra X), CC BY 4.0: [CREDITS.md](../../CREDITS.md) |
| `miru-player.gif` | Miru: the player with its line list, a tap on 汚れる, and the lookup | *Sintel* (2010) © Blender Foundation, [durian.blender.org](https://durian.blender.org), CC BY 3.0; Japanese subtitles from [download.blender.org/durian/subs/](https://download.blender.org/durian/subs/) |
| `kiku-1-home.png` | Kiku's Listen home on the demo Audiobookshelf | LibriVox recordings (public domain): [CREDITS.md](../../CREDITS.md) |
| `kiku-player.gif` | Kiku: the transcript following the audio, a tap on 小学校, and the lookup | 夏目漱石『坊っちゃん』, the [LibriVox recording](https://librivox.org/botchan-by-soseki-natsume-2/) read by ekzemplaro (public domain); the transcript is Kaku's own output (anime-whisper) for that clip, unedited |
| `hiku-1-home.png` | Hiku's screen in the app | Amatsubame's own |
| `hiku-2-lookup.png` | Hiku: the lookup of 無鉄砲 in Safari | 夏目漱石『坊っちゃん』on [Aozora Bunko](https://www.aozora.gr.jp/cards/000148/files/752_14964.html) (public domain) |

Dictionary entries in every lookup are [Jitendex](https://jitendex.org) (CC BY-SA 4.0).

## Taking them again
Each app's capture UI test (skipped unless `TEST_RUNNER_UITEST_CAPTURE=1`) attaches two full-screen
screenshots, `readme-1-home` and `readme-2-lookup`: `YomuUITests/ReaderUITests.testReadmeCapture`,
`MiruUITests/ReadmeCaptureUITests`, `KikuUITests/ReadmeCaptureUITests` (`testReadmeHome`, and
`testReadmeCapture` in memory with `docs/media/capture/kiku`: `clip.m4a`, the first 2:30 of the recording
above, and `transcript.json`, Kaku's transcript of it, both only for the capture) and
`HikuUITests/ExtensionLookupUITests.testReadmeCapture`. They run against the demo servers Setup offers.

1. `scripts/readme-screenshots.sh <simulator id> <folder> [apps]` builds each app, signs Miru and Kiku in
   (DevSetup), switches the simulator to dark mode with the status bar at 9:41, runs the tests and
   exports the screenshots as `<app>-1-home.png` and `<app>-2-lookup.png`. Server addresses, keys and
   passwords come from `README_*` environment variables (listed at the top of the script), never from
   the repo. One iPhone for all (an iPhone 17 Pro Max for these).
2. For Miru and Kiku the script also records the player (`<app>-raw.mp4`, and a screenshot about every
   half second). Cut their GIFs with `scripts/readme-gif.py`: `dump <raw.mp4> <frames> 600` decodes every
   recorded frame with its time, `strip` tiles every Nth to pick the steps, and
   `build <frames> <out.gif> 10 --band <frames>/<a playing frame>.png:<height> <first>-<last>@<cap> … hold:<frame>@3`
   samples about a second of the player, the tap and the popup at their real timing, then holds the
   popup. `--band` lays the top band (status bar and Dynamic Island) of one clean frame over every
   frame, so it stays perfectly still: the island pulses while media plays.

The simulator's recorder writes a frame only when it notices a change, so cutting the video by time
(`-ss`, `fps`) lands on the wrong frames, and it can miss a web view (the popup) until something else
changes: hence the decoded frames, and a screenshot to hold when the popup never made it into the video.
