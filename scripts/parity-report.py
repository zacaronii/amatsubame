#!/usr/bin/env python3
"""Totals and differences by cause for a parity run (hachidori-parity.sh <corpus>).

    python3 scripts/parity-report.py build.noindex/parity/lookups.jsonl

`expected` is Hachidori's engine with our deliberate rules applied; `ours` is the app's tap lookup.
"""
import collections
import json
import sys


def keys(entries):
    return [f"{e['expression']}/{e['reading']}" for e in entries]


def cause(record):
    ours, expected = keys(record['ours']), keys(record['expected'])
    if record['scanned'] != record['hachidoriText'][:len(record['scanned'])]:
        return 'the text looked up differs (our scan vs Hachidori\'s)'
    if ours == expected:
        return 'same entries, other dictionaries, inflections or match'
    if ours == expected[:len(ours)]:
        return f'ours stops at {len(ours)} results'
    if set(ours) == set(expected):
        return 'same entries, other order'
    if set(ours) < set(expected):
        return 'ours has fewer entries, in another order'
    return 'different entries'


def main(path):
    records = [json.loads(line) for line in open(path, encoding='utf-8')]
    totals = collections.Counter()
    causes = collections.Counter()
    examples = {}
    for r in records:
        ours, expected = r['ours'], r['expected']
        first = lambda entries: entries[0] if entries else {}
        totals['matched length'] += first(ours).get('matched') == first(expected).get('matched')
        totals['first entry'] += keys(ours[:1]) == keys(expected[:1])
        totals['first entry\'s inflections'] += first(ours).get('inflections') == first(expected).get('inflections')
        totals['ordered list'] += keys(ours) == keys(expected)
        totals['everything (dictionaries, inflections, match)'] += ours == expected
        if ours != expected:
            c = cause(r)
            causes[c] += 1
            examples.setdefault(c, r)
    n = len(records)
    by_source = collections.Counter(r['source'] for r in records)
    print(f'{n} taps: ' + ', '.join(f'{source} {count}' for source, count in by_source.items()))
    for name, count in totals.items():
        print(f'  {name}: {count}/{n}')
    for c, count in causes.most_common():
        r = examples[c]
        print(f'\n{c}: {count}\n  e.g. {r["source"]} 「{r["line"][:40]}」 at {r["utf16Offset"]}')
        print(f'    ours      {keys(r["ours"])[:5]} ({len(r["ours"])})')
        print(f'    Hachidori {keys(r["expected"])[:5]} ({len(r["expected"])})')


if __name__ == '__main__':
    main(sys.argv[1])
