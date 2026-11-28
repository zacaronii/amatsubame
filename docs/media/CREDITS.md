# Media credits

The README's images show the apps with content that may be shown publicly. Nothing comes from anyone's
private library or servers.

| File | Shows | Content and licence |
| --- | --- | --- |
| `banner.png`, `*-icon.png` | the swift and the app icons | Amatsubame's own artwork (GPL-3.0, like the repository); the banner's 「もう一話だけ…」 is drawn from the outlines of [M PLUS Rounded 1c](https://fonts.google.com/specimen/M+PLUS+Rounded+1c) ExtraBold (SIL Open Font License 1.1) |
| `yomu.gif` | Yomu: a tap on a speech bubble, and the lookup | *Pepper&Carrot* episode 1 in Japanese by David Revoy, [peppercarrot.com](https://www.peppercarrot.com), CC BY 4.0 |
| `miru.gif` | Miru: a tap on a word of the line, and the lookup | *Sintel* (2010) © Blender Foundation, [durian.blender.org](https://durian.blender.org), CC BY 3.0; Japanese subtitles from [download.blender.org/durian/subs/](https://download.blender.org/durian/subs/) |
| `kiku.gif` | Kiku: the transcript following the audio, and a tap on a word | 夏目漱石『坊っちゃん』, the [LibriVox recording](https://librivox.org/botchan-by-soseki-natsume-2/) read by ekzemplaro (public domain); the transcript is Kaku's own output (anime-whisper) for that clip, unedited |
| `hiku.gif` | Hiku: a tap on a word in Safari, and the lookup | 夏目漱石『坊っちゃん』on [Aozora Bunko](https://www.aozora.gr.jp/cards/000148/files/752_14964.html) (public domain) |

Dictionary entries in every GIF are [Jitendex](https://jitendex.org) (CC BY-SA 4.0).

## Recording them again
Each GIF is a quick tour from a capture UI test, skipped unless `TEST_RUNNER_UITEST_CAPTURE=1`:
`YomuUITests/ReaderUITests.testReadmeCapture`, `MiruUITests/ReadmeCaptureUITests`,
`HikuUITests/ExtensionLookupUITests.testReadmeCapture`, and `KikuUITests/ReadmeCaptureUITests` with
`TEST_RUNNER_UITEST_CAPTURE_FOLDER` set to `docs/media/capture/kiku` (`clip.m4a`, the first 2:30 of the
recording above, and `transcript.json`, Kaku's transcript of it: both only for the capture, not in any
app). They run against the demo servers Setup offers.

1. `scripts/record-readme-gif.sh <App> <simulator id> <folder>` builds the app, signs it in where it
   needs to (DevSetup), and runs the test while recording the simulator (`simctl io recordVideo`, status
   bar at 9:41) and taking a screenshot about every half second. Server addresses, keys and passwords
   come from `README_*` environment variables (listed at the top of the script), never from the repo.
   Yomu is recorded on an iPad simulator, the others on an iPhone; Miru and Kiku play muted.
2. `scripts/readme-gif.py dump <raw.mp4> <frames> <width>` decodes every recorded frame with its time
   (600 px wide for iPhone, 760 for iPad), and `strip` tiles every Nth frame to pick the steps.
3. `scripts/readme-gif.py build <frames> <out.gif> 10 <first>-<last>@<cap> … hold:9999@3` samples the
   chosen frame ranges at 10 fps with their real timing (stills cut to `<cap>` seconds) and ends on a
   held frame: copy the screenshot showing the popup into the frames folder as `f9999.png`, scaled to
   the same size and saved as RGB (`ffmpeg -i shot.png -vf "scale=600:-2,format=rgb24" f9999.png`).

The simulator's recorder writes a frame only when it notices a change, so cutting the video by time
(`-ss`, `fps`) lands on the wrong frames, and it can miss a web view (the lookup popup) entirely: hence
the decoded frames and the screenshots.
