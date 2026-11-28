# Lookup test fixtures

`parity-sample.tsv`: the taps `HachidoriParityTests` checks against Hachidori's own engine
(`scripts/hachidori-parity.sh`), one per line as `source<TAB>line<TAB>UTF-16 offset`, picked from a
corpus `scripts/parity-corpus.py` writes. The lines come from:

- Aozora Bunko (public domain): 夏目漱石『坊っちゃん』, 芥川龍之介『羅生門』, 宮沢賢治『銀河鉄道の夜』.
- Sintel's Japanese subtitles, © Blender Foundation, durian.blender.org, CC BY 3.0.
- Pepper&Carrot, by David Revoy and its Japanese translators, www.peppercarrot.com, CC BY 4.0.
- Words for tricky cases (particles, long vowels, small kana, loanwords, inflections, counters,
  okurigana variants, and spellings Jitendex has both as an entry and a redirect, or only as a redirect).
