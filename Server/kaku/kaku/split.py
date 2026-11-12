"""Re-splits timed words into sentences, so a mined sentence is a real sentence.

A sentence ends at 。！？ (or their half-width forms) and at a pause longer than `pause`
seconds. Whisper still leaves some lines far too long for a card (some run over
20 s), so a line longer than `max_length` is cut where the speaker paused longest, preferring a
clause ending (、 or けど, よね, から…), and only between words. A one-word fragment left over is
merged into the nearer neighbour.

Whisper's "words" in Japanese are its tokens, so a rare kanji compound arrives as one token per
kanji, and a long pause between them (Whisper's timing, or a dramatic pause) would cut the word:
遠 / 慮なく. Neither kind of cut happens between two kanji, or between a number and what follows
it (50 / 円), or before something no line starts with (を, a small kana, ー, closing punctuation:
手 / を振られた), unless the pause is longer than `WORD_PAUSE` or a too-long line has nowhere else to go.

Words carry the segment they came from, so flags from the model (no-speech probability,
compression ratio) can be attached to the sentences built from them.
"""
from __future__ import annotations

from dataclasses import dataclass, field

ENDERS = ('。', '！', '？', '!', '?')
# Where a long line can be cut without splitting a thought: after a comma or a clause ending.
CLAUSE_ENDINGS = ('、', ',', 'けど', 'けれど', 'けれども', 'よね', 'から', 'ので', 'って', 'たら', 'ても', 'でも', 'し')
# Neither half of a cut line is shorter than this (seconds).
MIN_PART = 2.0
# A pause longer than this splits even inside a word (seconds; Whisper can put 9 s inside one, like 遠慮 above).
WORD_PAUSE = 10.0


def _kanji(character):
    return '\u4e00' <= character <= '\u9fff' or '\u3400' <= character <= '\u4dbf' or character == '々'


def _digit(character):
    return '0' <= character <= '9' or '０' <= character <= '９'


# Japanese lines never start with these: the object particle, small kana, the long vowel mark,
# closing brackets and punctuation.
NO_LINE_START = set('をぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶー、。，．！？!?）)」』】〉》')


def holds_together(left, right):
    """True when a cut between these words would likely split one word (kanji to kanji, or a
    number to a kanji or a digit) or start a line with something no line starts with."""
    end, start = left.text.strip()[-1:], right.text.strip()[:1]
    if not end or not start:
        return False
    return (_kanji(end) and _kanji(start)) or (_digit(end) and (_kanji(start) or _digit(start))) or start in NO_LINE_START


@dataclass
class Word:
    text: str
    start: float
    end: float
    probability: float = 1.0
    segment: int = 0


@dataclass
class Sentence:
    words: list = field(default_factory=list)

    @property
    def text(self):
        return ''.join(word.text for word in self.words).strip()

    @property
    def start(self):
        return self.words[0].start

    @property
    def end(self):
        return self.words[-1].end

    @property
    def duration(self):
        return self.end - self.start

    @property
    def confidence(self):
        return sum(word.probability for word in self.words) / len(self.words)


def split(words, pause=0.8, max_length=15.0):
    """Groups words into sentences no longer than `max_length` seconds where possible."""
    words = [word for word in words if word.text.strip()]
    sentences = []
    current = Sentence()
    for index, word in enumerate(words):
        current.words.append(word)
        following = words[index + 1] if index + 1 < len(words) else None
        ends = word.text.strip().endswith(ENDERS)
        gap = following.start - word.end if following is not None else 0.0
        paused = gap > pause and (gap > WORD_PAUSE or not holds_together(word, following))
        if ends or paused or following is None:
            sentences.append(current)
            current = Sentence()
    cut = [part for sentence in sentences for part in _cut(sentence, max_length)]
    return _merge_fragments(cut)


def _cut(sentence, max_length):
    """Cuts a too-long sentence at its best boundary, again and again until each part fits
    (or no boundary leaves both parts at least MIN_PART long)."""
    if sentence.duration <= max_length or len(sentence.words) < 2:
        return [sentence]
    best, best_score = None, None
    for index in range(len(sentence.words) - 1):
        left, right = sentence.words[index], sentence.words[index + 1]
        if left.end - sentence.start < MIN_PART or sentence.end - right.start < MIN_PART:
            continue
        gap = max(0.0, right.start - left.end)
        clause = left.text.strip().endswith(CLAUSE_ENDINGS)
        # A clause ending counts like an extra half second of pause; ties go to the middle.
        # Any cut between words beats one inside a word.
        middle = abs((left.end - sentence.start) / sentence.duration - 0.5)
        score = (not holds_together(left, right), gap + (0.5 if clause else 0.0), -middle)
        if best_score is None or score > best_score:
            best, best_score = index, score
    if best is None:
        return [sentence]
    head, tail = Sentence(sentence.words[:best + 1]), Sentence(sentence.words[best + 1:])
    return _cut(head, max_length) + _cut(tail, max_length)


def _merge_fragments(sentences):
    """Merges each one-word fragment (cut off by a pause, like a lone ね) into the neighbour
    it's closer to in time. A one-word sentence that ends properly (はい。) stays."""
    result = list(sentences)
    index = 0
    while index < len(result):
        sentence = result[index]
        if len(sentence.words) > 1 or sentence.text.endswith(ENDERS) or len(result) == 1:
            index += 1
            continue
        before = result[index - 1] if index > 0 else None
        after = result[index + 1] if index + 1 < len(result) else None
        gap_before = sentence.start - before.end if before else float('inf')
        gap_after = after.start - sentence.end if after else float('inf')
        if before and gap_before <= gap_after:
            before.words.extend(sentence.words)
            del result[index]
        elif after:
            after.words[:0] = sentence.words
            del result[index]
        else:
            index += 1
    return result


def repeated(sentences, run=3):
    """Indexes of sentences that repeat the one before (a run of `run` or more identical
    lines is the classic hallucination loop)."""
    flagged = set()
    start = 0
    for index in range(1, len(sentences) + 1):
        if index < len(sentences) and sentences[index].text == sentences[start].text:
            continue
        if index - start >= run:
            flagged.update(range(start + 1, index))
        start = index
    return flagged
