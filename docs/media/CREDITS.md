# Media credits

The README's images show the apps with content that may be shown publicly. Nothing comes from anyone's
private library or servers.

| File | Shows | Content and licence |
| --- | --- | --- |
| `banner.png`, `*-icon.png` | the swift and the app icons | Amatsubame's own artwork (GPL-3.0, like the repository) |
| `yomu.gif` | Yomu: a tap on a speech bubble, and the lookup | *Pepper&Carrot* episode 1 in Japanese by David Revoy, [peppercarrot.com](https://www.peppercarrot.com), CC BY 4.0 |
| `miru.gif` | Miru: a tap on a word of the line, and the lookup | *Sintel* (2010) © Blender Foundation, [durian.blender.org](https://durian.blender.org), CC BY 3.0; Japanese subtitles from [download.blender.org/durian/subs/](https://download.blender.org/durian/subs/) |
| `hiku.gif` | Hiku: a tap on a word in Safari, and the lookup | 夏目漱石『坊っちゃん』on [Aozora Bunko](https://www.aozora.gr.jp/cards/000148/files/752_14964.html) (public domain) |

Dictionary entries in every GIF are [Jitendex](https://jitendex.org) (CC BY-SA 4.0).

## Recording them again
Each GIF comes from a capture UI test, skipped unless `TEST_RUNNER_UITEST_CAPTURE=1`:
`YomuUITests/ReaderUITests.testReadmeCapture`, `MiruUITests/ReadmeCaptureUITests`,
`HikuUITests/ExtensionLookupUITests.testReadmeCapture`. Record the simulator around the test with
`xcrun simctl io <device> recordVideo --codec=h264 out.mp4` (status bar set with `simctl status_bar
… override --time 9:41`), then make a 320 px GIF in two passes with a palette:

    ffmpeg -ss <start> -i out.mp4 -t <seconds> -vf "fps=12,scale=320:-2:flags=lanczos" -fps_mode cfr part.mp4
    ffmpeg -i part.mp4 -filter_complex "split[x][y];[x]palettegen=stats_mode=diff[p];[y][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" out.gif

The simulator records only frames that change, so cut with `-ss` before `-i` and render each part at a
constant rate (`-fps_mode cfr`) before joining parts with the concat demuxer. Miru plays muted
(`UITEST_MUTE`, Debug builds only).
