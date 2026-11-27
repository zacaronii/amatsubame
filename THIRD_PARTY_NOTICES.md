# Third-party notices

Amatsubame's apps are licensed under the GNU General Public License, version 3 only (GPL-3.0-only) (`LICENSE`). Kaku, the
transcription server in `Server/kaku`, is a separate program under the MIT License
(`Server/kaku/LICENSE`).

They include or use the following. Each keeps its own license; the full texts are in the folders named.

## Included in this repository
| Project | License | Where |
| --- | --- | --- |
| [hoshidicts](https://github.com/Manhhao/hoshidicts), as [bee-san's fork](https://github.com/bee-san/hoshidicts) | GPL-3.0 | `Vendor/hoshidicts` (`LICENSE`, local changes in `VENDORED.md`) |
| glaze | MIT | `Vendor/hoshidicts/external/glaze` |
| libdeflate | MIT | `Vendor/hoshidicts/external/libdeflate` |
| unordered_dense | MIT | `Vendor/hoshidicts/external/unordered_dense` |
| utf8proc | MIT and the Unicode data license | `Vendor/hoshidicts/external/utf8proc` |
| utfcpp | BSL-1.0 | `Vendor/hoshidicts/external/utfcpp` |
| xxHash | BSD-2-Clause | `Vendor/hoshidicts/external/xxHash` |
| lzokay | MIT | `Vendor/hoshidicts/external/lzokay` |
| gumbo-parser (Nokogiri's) | Apache-2.0 | `Vendor/hoshidicts/external/gumbo-parser` |
| [libfvad](https://github.com/dpirch/libfvad) (WebRTC's voice activity detector) | BSD-3-Clause | `Vendor/libfvad` (`LICENSE`, `VENDORED.md`) |
| Mozilla CA certificate list | MPL-2.0 | `Packages/Player/Sources/PlayerKit/Resources/cacert.pem` |
| Yomitan Japanese transforms test data | GPL-3.0 | `Packages/Dictionary/Tests/DictionaryTests/Fixtures/yomitan-japanese-transforms.json` |
| [Hachidori](https://github.com/bee-san/hachidori)'s compact definition summary, ported to Swift | GPL-3.0 | `Packages/Lookup/Sources/Lookup/CompactDefinitionSummary.swift` (from `extension/render/popup.js` and `render/reader.css`) |

## Swift packages (fetched when building)
| Project | License |
| --- | --- |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | MIT |
| [zstd](https://github.com/facebook/zstd) | BSD-3-Clause (dual BSD/GPL-2.0) |
| [MPVKit](https://github.com/mpvkit/MPVKit) (LGPL build) with mpv, FFmpeg and MoltenVK | LGPL-3.0 (MPVKit), LGPL-2.1+ (mpv, FFmpeg), Apache-2.0 (MoltenVK), plus the licenses of the libraries MPVKit bundles |
| [AetherEngine](https://github.com/zacaronii/AetherEngine) (the owner's fork of [superuser404notfound/AetherEngine](https://github.com/superuser404notfound/AetherEngine); spike only) | LGPL-3.0 with an App Store / DRM exception |
| [FFmpegBuild](https://github.com/zacaronii/FFmpegBuild) (fork) with FFmpeg, dav1d, zimg and libzvbi, for AetherEngine | LGPL-2.1 (FFmpeg, libzvbi), BSD-2-Clause (dav1d), WTFPL (zimg), MIT (libzvbi's URE code) |
| [LibDovi](https://github.com/superuser404notfound/LibDovi) (dovi_tool's libdovi), for AetherEngine | MIT |
| [SMBClient](https://github.com/kishikawakatsumi/SMBClient), for AetherEngine | MIT |

## Followed, not copied
- [Hachidori](https://github.com/bee-san/hachidori) (GPL-3.0): how lookups are counted and the
  "Looked up N times" chip (docs/hachidori.md).
- [Yomitan](https://github.com/yomidevs/yomitan) (GPL-3.0): the dictionary format, deinflection rules
  (through hoshidicts) and how structured-content entries are rendered.

## Downloaded at runtime (not in this repository)
- [nemu-ocr-coreml](https://huggingface.co/nemu-pm/nemu-ocr-coreml) manga OCR models (Apache-2.0), pinned in `OCRModelStore`.
- Recommended dictionaries (Hachidori's defaults: Jitendex, JMnedict, Bee's Ultimate Kanji Dictionary, Jiten,
  Bee's Ultimate Grammar Dictionary; and Kanjium, optional), each under its own license
  shown in the apps' About screens.
- Character names: casts (names and pictures) from [AniList](https://anilist.co)'s public API under its terms of use, for
  the series open in Yomu and Miru only; which AniList series a manga or light novel is, from
  [MangaBaka](https://mangabaka.org) (its data CC BY-NC-SA 4.0). Credited in the apps' About screens.
- Kaku: [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (MIT), the
  [anime-whisper](https://huggingface.co/litagin/anime-whisper) weights (MIT; converted on the server by
  `Server/kaku/convert-model.sh`, with transformers (Apache-2.0), CTranslate2 (MIT) and PyTorch (BSD),
  none of them shipped) and, optionally, the Whisper large-v3 weights (MIT), plus its Python
  dependencies listed in `Server/kaku/Dockerfile`.
