"""Whisper through faster-whisper on the GPU (the model chosen in milestone 0)."""
from __future__ import annotations

import gc
import logging
import threading

from .transcript import Segment

log = logging.getLogger('kaku.pipeline')

# The punctuated prompt makes large-v3 write 。、 (without it, it often writes none and nothing
# splits). Batched inference cuts the audio at voice detection into independent chunks and gives
# each the prompt; sequential decoding (milestone 0) used it only for the first 30 s once
# conditioning on previous text was off, so long episodes came out unpunctuated. Batched is also
# 3–5× faster. (`hotwords`, which repeats a prompt every window, leaked the prompt's words into
# the text and lost speech: tried 2026-11-05.)
PROMPT = 'こんにちは。今日は、ポッドキャストの話をしましょう。そうですね、楽しみです！'
SETTINGS = dict(language='ja', beam_size=5, vad_filter=True, word_timestamps=True)
BATCH_SIZE = 8


class WordView:
    __slots__ = ('text', 'start', 'end', 'probability')

    def __init__(self, word):
        self.text, self.start, self.end, self.probability = word.word, word.start, word.end, word.probability


class WhisperTranscriber:
    def __init__(self, model='large-v3', models_dir=None):
        self.name = model
        self.prompt = PROMPT
        self.models_dir = models_dir
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

    def load(self):
        with self.lock:
            if self.model is None:
                from faster_whisper import BatchedInferencePipeline, WhisperModel
                log.info('loading %s', self.name)
                self.model = WhisperModel(self.name, device='cuda', compute_type='float16', download_root=self.models_dir)
                self.batched = BatchedInferencePipeline(model=self.model)
            return self.batched

    def unload(self):
        with self.lock:
            self.model = self.batched = None
            gc.collect()

    def transcribe(self, wav, progress=lambda seconds: None, prompt=PROMPT):
        model = self.load()
        results, _ = model.transcribe(wav, batch_size=BATCH_SIZE, initial_prompt=prompt or PROMPT, **SETTINGS)
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
