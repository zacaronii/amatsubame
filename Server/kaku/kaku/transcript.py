"""Builds the transcript JSON (docs/AUDIO_PLAN.md, "Transcript format") from timed words, drops
known hallucinations, and writes the files."""
from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass

from .split import ENDERS, Word, repeated, split

def prompt_sentences(prompt):
    """The sentences of the prompt, ending at 。！？."""
    found, current = set(), ''
    for character in prompt:
        current += character
        if character in ENDERS:
            found.add(current.strip())
            current = ''
    if current.strip():
        found.add(current.strip())
    return found


@dataclass
class Segment:
    """What the model returns per segment, reduced to what the filters need."""
    words: list
    no_speech_prob: float = 0.0
    avg_logprob: float = 0.0
    compression_ratio: float = 1.0

    @property
    def no_speech(self):
        return self.no_speech_prob > 0.6 and self.avg_logprob < -1.0

    @property
    def looping(self):
        return self.compression_ratio > 2.4


def sentences(segments, prompt=''):
    """Sentences from the model's segments, without hallucinations:
    - runs of 3 or more identical lines keep only the first;
    - a sentence that is one of the prompt's is dropped;
    - sentences that start in a segment the model itself thinks has no speech are dropped;
    - a segment with a high compression ratio (repetitive text) halves its sentences' confidence."""
    words = []
    for index, segment in enumerate(segments):
        for word in segment.words:
            words.append(Word(word.text, word.start, word.end, word.probability, index))
    built = split(words)
    loops = repeated(built)
    leaked = prompt_sentences(prompt) if prompt else set()
    out = []
    for index, sentence in enumerate(built):
        segment = segments[sentence.words[0].segment]
        if index in loops or segment.no_speech or sentence.text in leaked:
            continue
        out.append(_entry(sentence, sentence.confidence * (0.5 if segment.looping else 1.0)))
    return out


def _entry(sentence, confidence):
    return {
        'start': round(sentence.start, 2), 'end': round(sentence.end, 2), 'text': sentence.text,
        'confidence': round(confidence, 3),
        'words': [{'text': w.text, 'start': round(w.start, 2), 'end': round(w.end, 2),
                   'confidence': round(w.probability, 3)} for w in sentence.words],
    }


def resplit(transcript):
    """The same transcript with its stored words split into lines again (after `split` changes),
    without the model. A line keeps the confidence penalty of the line its first word was in.
    Returns None when nothing changes."""
    old = transcript['sentences']
    words = []
    for index, line in enumerate(old):
        for word in line['words']:
            words.append(Word(word['text'], word['start'], word['end'], word.get('confidence', 1.0), index))
    new = []
    for sentence in split(words):
        first = old[sentence.words[0].segment]
        plain = sum(w.get('confidence', 1.0) for w in first['words']) / max(len(first['words']), 1)
        factor = first['confidence'] / plain if plain else 1.0
        new.append(_entry(sentence, sentence.confidence * min(factor, 1.0)))
    if [line['text'] for line in new] == [line['text'] for line in old]:
        return None
    return dict(transcript, sentences=new)


def document(item, source, sentence_list):
    return {'item': item, 'source': source, 'sentences': sentence_list}


def vtt(transcript):
    def stamp(seconds):
        millis = int(round(seconds * 1000))
        hours, rest = divmod(millis, 3_600_000)
        minutes, rest = divmod(rest, 60_000)
        secs, millis = divmod(rest, 1000)
        return f'{hours:02}:{minutes:02}:{secs:02}.{millis:03}'
    cues = [f"{stamp(s['start'])} --> {stamp(s['end'])}\n{s['text']}" for s in transcript['sentences']]
    return 'WEBVTT\n\n' + '\n\n'.join(cues) + '\n'


def srt(transcript):
    """SubRip, for players and Jellyfin (Miru keeps a Kaku subtitle as an .srt like a Jimaku pick)."""
    def stamp(seconds):
        millis = int(round(seconds * 1000))
        hours, rest = divmod(millis, 3_600_000)
        minutes, rest = divmod(rest, 60_000)
        secs, millis = divmod(rest, 1000)
        return f'{hours:02}:{minutes:02}:{secs:02},{millis:03}'
    cues = [f"{index}\n{stamp(s['start'])} --> {stamp(s['end'])}\n{s['text']}" for index, s in enumerate(transcript['sentences'], 1)]
    return '\n\n'.join(cues) + '\n'


def write(folder, name, transcript):
    """Writes `<name>.json` and `<name>.vtt` atomically; returns the JSON path."""
    os.makedirs(folder, exist_ok=True)
    for extension, text in (('vtt', vtt(transcript)), ('json', json.dumps(transcript, ensure_ascii=False))):
        handle, temporary = tempfile.mkstemp(dir=folder, suffix='.tmp')
        with os.fdopen(handle, 'w', encoding='utf-8') as file:
            file.write(text)
        os.replace(temporary, os.path.join(folder, f'{name}.{extension}'))
    return os.path.join(folder, f'{name}.json')
