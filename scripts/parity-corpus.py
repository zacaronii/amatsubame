#!/usr/bin/env python3
"""Writes a corpus of taps for scripts/hachidori-parity.sh: real text tapped at every Japanese
character, plus tricky categories. Several thousand taps; the sources are downloaded once into
build.noindex/parity/sources (all licence-clean):

- Aozora Bunko (public domain): 坊っちゃん, 羅生門, 銀河鉄道の夜
- Sintel's Japanese subtitles (Blender Foundation, CC BY 3.0)
- Pepper&Carrot's Japanese pages (David Revoy and its translators, CC BY 4.0)

    python3 scripts/parity-corpus.py [--jitendex <jitendex zip>] [--out build.noindex/parity/corpus.tsv]

With --jitendex, it adds Jitendex's kana spellings that have both an entry and a redirect, and 300
redirect-only spellings. Each line is "source<TAB>line<TAB>UTF-16 offset".
"""
import argparse
import collections
import glob
import html
import json
import os
import random
import re
import urllib.parse
import urllib.request
import zipfile

AGENT = {'User-Agent': 'Amatsubame/0.4 CFNetwork'}
JAPANESE = re.compile(r'[぀-ヿ一-鿿々〆ヶ]')
AOZORA = {'botchan': 'https://www.aozora.gr.jp/cards/000148/files/752_ruby_2438.zip',
          'rashomon': 'https://www.aozora.gr.jp/cards/000879/files/127_ruby_150.zip',
          'gingatetsudo': 'https://www.aozora.gr.jp/cards/000081/files/456_ruby_145.zip'}
SINTEL = 'https://download.blender.org/durian/subs/sintel_jp.srt'
PEPPER = 'https://framagit.org/api/v4/projects/peppercarrot%2Fwebcomics/repository/tree'
# Taps per source (each line is tapped at every Japanese character until the budget is spent).
BUDGET = {'botchan': 1800, 'rashomon': 600, 'gingatetsudo': 1000, 'sintel': 10**6, 'peppercarrot': 1600}
CATEGORIES = {
    'particles-enders': 'なあ ねえ よお なぁ ねぇ よぉ ぞ ぜ わ わよ かしら よね っけ じゃん だろ でしょ のに けど か な ね よ さ もん ものか',
    'long-vowel': 'すげー すげえ うめえ やべぇ やべー ねー ほんとー だよー すごーい おーい えー うわー かっけー',
    'small-kana': 'ぁ ぃ ぅ ぇ ぉ っ ゃ ゅ ょ ヴァ ファイル ちぇっ ぎゃあ',
    'katakana-loans': 'コーヒー パソコン テレビ スマホ アイスクリーム コンビニ インターネット ウイルス ウィルス メール ゲーム プレゼント',
    'deinflection': '食べた 食べない 食べたい 食べられる 食べさせる 食べさせられなかった 行って 書かない 読みたかった 見られた '
                    '抱きてぇ 食いてえ 寒くない 高かった 静かな 来なかった しなきゃ 行っちゃった 言わなきゃ',
    'counters-numbers': '三匹 二十歳 一人 二人 七つ 百円 千 五本 三日 一日 八時 十分 九月 四回',
    'okurigana-variants': '受付 受け付け 申込み 申し込み 取扱い 取り扱い 引越し 引っ越し 売上 売り上げ 落とし物 落し物',
}


def fetch(url, path):
    if not os.path.exists(path):
        with urllib.request.urlopen(urllib.request.Request(url, headers=AGENT), timeout=60) as reply:
            data = reply.read()
        with open(path, 'wb') as f:
            f.write(data)
    return path


def aozora(path):
    archive = zipfile.ZipFile(path)
    text = archive.read(next(n for n in archive.namelist() if n.endswith('.txt'))).decode('shift_jis', errors='replace')
    parts = re.split(r'-{20,}', text)
    body = (parts[2] if len(parts) > 2 else text).split('底本：')[0]
    body = re.sub(r'《[^》]*》', '', body).replace('｜', '')
    body = re.sub(r'［＃[^］]*］', '', body)
    return [line.strip().replace('　', '') for line in body.splitlines() if JAPANESE.search(line)]


def pepper_carrot(folder):
    os.makedirs(folder, exist_ok=True)
    get = lambda url: json.load(urllib.request.urlopen(urllib.request.Request(url, headers=AGENT), timeout=60))
    if not glob.glob(f'{folder}/*.svg'):
        for episode in (e['name'] for e in get(PEPPER + '?per_page=100') if e['type'] == 'tree' and e['name'].startswith('ep')):
            try:
                pages = get(PEPPER + '?per_page=50&path=' + urllib.parse.quote(f'{episode}/lang/ja'))
            except OSError:
                continue
            for page in (p for p in pages if p['name'].endswith('.svg')):
                fetch('https://framagit.org/peppercarrot/webcomics/-/raw/master/' + urllib.parse.quote(page['path']),
                      f"{folder}/{page['name']}")
    lines = []
    for path in sorted(glob.glob(f'{folder}/*.svg')):
        for block in re.findall(r'<(?:flowRoot|text)\b.*?</(?:flowRoot|text)>', open(path, encoding='utf-8').read(), re.S):
            line = re.sub(r'\s+', '', html.unescape(re.sub(r'<[^>]+>', '', block)))
            if JAPANESE.search(line):
                lines.append(line)
    return lines


def taps(line):
    """The UTF-16 offset of every Japanese character, as a tap gives it."""
    offset, found = 0, []
    for character in line:
        if JAPANESE.match(character):
            found.append(offset)
        offset += len(character.encode('utf-16-le')) // 2
    return found


def jitendex_spellings(path):
    kana = re.compile(r'^[぀-ヿー]+$')
    own, redirects = set(), set()
    archive = zipfile.ZipFile(path)
    for name in (n for n in archive.namelist() if n.startswith('term_bank')):
        for entry in json.loads(archive.read(name)):
            (redirects if any(isinstance(d, list) for d in entry[5]) else own).add(entry[0])
    dual = sorted(t for t in redirects if kana.match(t) and t in own)
    return dual, random.sample(sorted(redirects - own), 300)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--jitendex')
    parser.add_argument('--out', default='build.noindex/parity/corpus.tsv')
    args = parser.parse_args()
    random.seed(7)
    sources = 'build.noindex/parity/sources'
    os.makedirs(sources, exist_ok=True)
    lines = {name: aozora(fetch(url, f'{sources}/{name}.zip')) for name, url in AOZORA.items()}
    subtitles = open(fetch(SINTEL, f'{sources}/sintel_jp.srt'), encoding='utf-8-sig').read().replace('\r', '')
    lines['sintel'] = [line.strip() for line in subtitles.split('\n') if JAPANESE.search(line) and '-->' not in line]
    lines['peppercarrot'] = pepper_carrot(f'{sources}/peppercarrot')

    rows = []
    for source, source_lines in lines.items():
        source_lines = [line for line in source_lines if 2 <= len(line) <= 120]
        if source != 'sintel':
            random.shuffle(source_lines)
        count = 0
        for line in source_lines:
            rows += [(source, line, offset) for offset in taps(line)]
            count += len(taps(line))
            if count >= BUDGET[source]:
                break
    categories = {name: words.split() for name, words in CATEGORIES.items()}
    if args.jitendex:
        categories['jitendex-dual-entry'], categories['jitendex-redirect-only'] = jitendex_spellings(args.jitendex)
    for category, words in categories.items():
        for word in words:
            rows.append((category, word, 0))
            if category == 'katakana-loans':
                rows.append((category, word + 'だ。', 0))
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, 'w', encoding='utf-8') as f:
        f.writelines(f'{source}\t{line}\t{offset}\n' for source, line, offset in rows)
    counts = collections.Counter(source for source, _, _ in rows)
    print(f'{len(rows)} taps in {args.out}: ' + ', '.join(f'{s} {n}' for s, n in counts.items()))


if __name__ == '__main__':
    main()
