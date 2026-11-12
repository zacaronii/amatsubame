# Third-party notices

Amatsubame's apps are licensed under the GNU General Public License v3.0 (`LICENSE`). Kaku, the
transcription server in `Server/kaku`, is a separate program under the MIT License
(`Server/kaku/LICENSE`).

They include or use the following. Each keeps its own license; the full texts are in the folders named.

## Included in this repository
| Project | License | Where |
| --- | --- | --- |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | GPL-3.0 | `Vendor/hoshidicts` (`LICENSE`, local changes in `VENDORED.md`) |
| glaze | MIT | `Vendor/hoshidicts/external/glaze` |
| libdeflate | MIT | `Vendor/hoshidicts/external/libdeflate` |
| unordered_dense | MIT | `Vendor/hoshidicts/external/unordered_dense` |
| utf8proc | MIT and the Unicode data license | `Vendor/hoshidicts/external/utf8proc` |
| utfcpp | BSL-1.0 | `Vendor/hoshidicts/external/utfcpp` |
| xxHash | BSD-2-Clause | `Vendor/hoshidicts/external/xxHash` |
| [libfvad](https://github.com/dpirch/libfvad) (WebRTC's voice activity detector) | BSD-3-Clause | `Vendor/libfvad` (`LICENSE`, `VENDORED.md`) |
| Mozilla CA certificate list | MPL-2.0 | `Packages/Player/Sources/PlayerKit/Resources/cacert.pem` |
| Yomitan Japanese transforms test data | GPL-3.0 | `Packages/Dictionary/Tests/DictionaryTests/Fixtures/yomitan-japanese-transforms.json` |

## Swift packages (fetched when building)
| Project | License |
| --- | --- |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | MIT |
| [zstd](https://github.com/facebook/zstd) | BSD-3-Clause (dual BSD/GPL-2.0) |
| [MPVKit](https://github.com/mpvkit/MPVKit) (LGPL build) with mpv, FFmpeg and MoltenVK | LGPL-3.0 (MPVKit), LGPL-2.1+ (mpv, FFmpeg), Apache-2.0 (MoltenVK), plus the licenses of the libraries MPVKit bundles |

## Followed, not copied
- [Yomitan](https://github.com/yomidevs/yomitan) (GPL-3.0): the dictionary format, deinflection rules
  (through hoshidicts) and how structured-content entries are rendered.

## Downloaded at runtime (not in this repository)
- [nemu-ocr-coreml](https://huggingface.co/nemu-pm/nemu-ocr-coreml) manga OCR models (Apache-2.0), pinned in `OCRModelStore`.
- Recommended dictionaries (Jitendex, JMnedict, KANJIDIC, Jiten, Kanjium), each under its own license
  shown in the apps' About screens.
- Kaku: [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (MIT) and the Whisper large-v3
  weights (MIT), plus its Python dependencies listed in `Server/kaku/Dockerfile`.
