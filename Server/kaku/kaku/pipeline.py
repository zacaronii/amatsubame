"""Whisper through faster-whisper on the GPU: anime-whisper by default (docs/kaku.md ▸ Model)."""
from __future__ import annotations

import gc
import json
import logging
import os
import threading

from .transcript import Segment

log = logging.getLogger('kaku.pipeline')

# litagin/anime-whisper, converted to CTranslate2 float16 by `python3 -m kaku.convert` (it has no
# ready faster-whisper build). It beat large-v3 on anime, audiobooks and podcasts (2026-11-24).
ANIME_WHISPER = 'anime-whisper'
ANIME_WHISPER_FOLDER = 'anime-whisper-ct2'
# Its 2-layer decoder: word timestamps need alignment heads from the last layer (the converted
# config carries large-v3's, which crash `word_timestamps`).
ANIME_WHISPER_HEADS = [[1, head] for head in range(20)]

# large-v3 only: the punctuated prompt makes it write 。、 (without it, it often writes none and
# nothing splits). Batched inference cuts the audio at voice detection into independent chunks
# and gives each the prompt. (`hotwords`, which repeats a prompt every window, leaked the prompt's
# words into the text and lost speech: tried 2026-11-05.) anime-whisper punctuates without one,
# and its authors advise against prompting it.
PROMPT = 'こんにちは。今日は、ポッドキャストの話をしましょう。そうですね、楽しみです！'
# Punctuated like the podcast prompt, without its topic: Jellyfin's episodes (drama, anime).
JELLYFIN_PROMPT = 'こんにちは。元気？うん、元気だよ。そうか、よかった！'
SETTINGS = dict(language='ja', beam_size=5, vad_filter=True, word_timestamps=True)
BATCH_SIZE = 8


class ModelNotReady(RuntimeError):
    """The converted model is missing or wrong (run `python3 -m kaku.convert`)."""


def check_converted(folder):
    """Raises ModelNotReady unless `folder` holds a usable anime-whisper conversion."""
    config = os.path.join(folder, 'config.json')
    if not os.path.exists(os.path.join(folder, 'model.bin')) or not os.path.exists(config):
        raise ModelNotReady(f'No converted anime-whisper in {folder}: run `python3 -m kaku.convert` once (docs/kaku.md ▸ Model).')
    if not os.path.exists(os.path.join(folder, 'tokenizer.json')):
        raise ModelNotReady(f'{folder} has no tokenizer.json: run `python3 -m kaku.convert` again.')
    with open(config, encoding='utf-8') as file:
        heads = json.load(file).get('alignment_heads')
    if heads != ANIME_WHISPER_HEADS:
        raise ModelNotReady(f'{folder}/config.json has the wrong alignment_heads (word timestamps would crash): '
                            'run `python3 -m kaku.convert` again.')


def default_prompt(model, jellyfin):
    """What `model` is primed with when KAKU_PROMPT isn't set."""
    if model == ANIME_WHISPER:
        return ''
    return JELLYFIN_PROMPT if jellyfin else PROMPT


class WordView:
    __slots__ = ('text', 'start', 'end', 'probability')

    def __init__(self, word):
        self.text, self.start, self.end, self.probability = word.word, word.start, word.end, word.probability


class WhisperTranscriber:
    def __init__(self, model=ANIME_WHISPER, models_dir=None, chunk_length=15, prompt=None):
        self.name = model
        self.models_dir = models_dir
        self.chunk_length = chunk_length
        # None: the model's default (`default_prompt`); '' or a text: that, for everything.
        self.prompt = prompt
        self.model = None
        self.batched = None
        self.lock = threading.Lock()

    @property
    def version(self):
        import faster_whisper
        return f'faster-whisper {faster_whisper.__version__}'

    @property
    def loaded(self):
        return self.model is not None

    def prompt_for(self, jellyfin=False):
        return self.prompt if self.prompt is not None else default_prompt(self.name, jellyfin)

    def check(self):
        """Raises ModelNotReady when the model can't load (the conversion is missing or wrong)."""
        self.location()

    def location(self):
        """What faster-whisper loads: the converted folder for anime-whisper (checked), else the name."""
        if self.name != ANIME_WHISPER:
            return self.name
        folder = os.path.join(self.models_dir or '/models', ANIME_WHISPER_FOLDER)
        check_converted(folder)
        return folder

    def load(self):
        with self.lock:
            if self.model is None:
                from faster_whisper import BatchedInferencePipeline, WhisperModel
                location = self.location()
                log.info('loading %s', location)
                # A name downloads into the Hugging Face cache (HF_HOME, the same models volume).
                self.model = WhisperModel(location, device='cuda', compute_type='float16')
                self.batched = BatchedInferencePipeline(model=self.model)
            return self.batched

    def unload(self):
        with self.lock:
            self.model = self.batched = None
            gc.collect()

    def transcribe(self, wav, progress=lambda seconds: None, prompt=''):
        """`prompt` '' (or None): no prompt at all."""
        model = self.load()
        results, _ = model.transcribe(wav, batch_size=BATCH_SIZE, initial_prompt=prompt or None,
                                      chunk_length=self.chunk_length, **SETTINGS)
        segments = []
        for result in results:
            segments.append(Segment(words=[WordView(word) for word in result.words or []],
                                    no_speech_prob=result.no_speech_prob, avg_logprob=result.avg_logprob,
                                    compression_ratio=result.compression_ratio))
            progress(result.end)
        return segments


def gpu_memory():
    """(used MB, total MB) of the whole card, or None without NVML."""
    try:
        import pynvml
        pynvml.nvmlInit()
        info = pynvml.nvmlDeviceGetMemoryInfo(pynvml.nvmlDeviceGetHandleByIndex(0))
        return round(info.used / 2**20), round(info.total / 2**20)
    except Exception:
        return None
