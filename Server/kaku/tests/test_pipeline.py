import json
import os
import sys
import types

import pytest

from kaku.config import Config
from kaku.convert import fix_alignment_heads
from kaku.pipeline import (ANIME_WHISPER_FOLDER, ANIME_WHISPER_HEADS, JELLYFIN_PROMPT, PROMPT, ModelNotReady,
                           WhisperTranscriber, check_converted)


class FakeBatched:
    """Stands in for faster-whisper's BatchedInferencePipeline: records what transcribe gets."""

    def __init__(self):
        self.calls = []

    def transcribe(self, wav, **options):
        self.calls.append(options)
        word = types.SimpleNamespace(word='はい', start=0.0, end=0.4, probability=0.9)
        result = types.SimpleNamespace(words=[word], no_speech_prob=0.0, avg_logprob=-0.1, compression_ratio=1.0, end=0.4)
        return iter([result]), None


def loaded(transcriber):
    transcriber.model = object()
    transcriber.batched = FakeBatched()
    return transcriber


def test_no_prompt_and_the_chunk_length_go_through():
    transcriber = loaded(WhisperTranscriber('anime-whisper', chunk_length=15))
    transcriber.transcribe('audio.wav', prompt=transcriber.prompt_for(jellyfin=False))
    options = transcriber.batched.calls[0]
    assert options['initial_prompt'] is None, 'anime-whisper is never primed'
    assert options['chunk_length'] == 15
    assert options['language'] == 'ja' and options['word_timestamps'] and options['vad_filter'] and options['beam_size'] == 5


def test_an_empty_prompt_means_none_not_the_podcast_prompt():
    transcriber = loaded(WhisperTranscriber('large-v3', chunk_length=30, prompt=''))
    transcriber.transcribe('audio.wav', prompt=transcriber.prompt_for(jellyfin=False))
    assert transcriber.batched.calls[0]['initial_prompt'] is None
    assert transcriber.batched.calls[0]['chunk_length'] == 30


def test_prompts_by_model_and_setting():
    assert WhisperTranscriber('anime-whisper').prompt_for(jellyfin=True) == ''
    large = WhisperTranscriber('large-v3')
    assert large.prompt_for(jellyfin=False) == PROMPT and large.prompt_for(jellyfin=True) == JELLYFIN_PROMPT
    assert WhisperTranscriber('anime-whisper', prompt='はい。').prompt_for(jellyfin=True) == 'はい。'


def test_settings_from_the_environment():
    base = {'AUDIOBOOKSHELF_URL': 'http://abs', 'AUDIOBOOKSHELF_API_KEY': 'k', 'KAKU_API_TOKEN': 't'}
    config = Config.from_env(base)
    assert (config.model, config.chunk_length, config.prompt, config.models_dir) == ('anime-whisper', 15, None, '/models')
    config = Config.from_env(dict(base, KAKU_MODEL='large-v3', KAKU_CHUNK_LENGTH='30', KAKU_PROMPT='none'))
    assert (config.model, config.chunk_length, config.prompt) == ('large-v3', 30, '')
    # Compose passes an empty KAKU_PROMPT when it isn't set: the model's default.
    assert Config.from_env(dict(base, KAKU_PROMPT='')).prompt is None
    assert Config.from_env(dict(base, KAKU_PROMPT='はい。')).prompt == 'はい。'


def converted(folder, heads=ANIME_WHISPER_HEADS, tokenizer=True):
    os.makedirs(folder, exist_ok=True)
    for name in ['model.bin'] + (['tokenizer.json'] if tokenizer else []):
        open(os.path.join(folder, name), 'w').close()
    with open(os.path.join(folder, 'config.json'), 'w') as file:
        json.dump({'alignment_heads': heads, 'lang_ids': [1]}, file)
    return folder


def test_the_conversion_is_checked(tmp_path):
    folder = str(tmp_path / ANIME_WHISPER_FOLDER)
    transcriber = WhisperTranscriber('anime-whisper', models_dir=str(tmp_path))
    with pytest.raises(ModelNotReady, match='kaku.convert'):
        transcriber.check()
    converted(folder, tokenizer=False)
    with pytest.raises(ModelNotReady, match='tokenizer.json'):
        transcriber.check()
    # large-v3's heads, as the converter writes them: word timestamps would crash.
    converted(folder, heads=[[10, 0], [31, 19]])
    with pytest.raises(ModelNotReady, match='alignment_heads'):
        transcriber.check()
    fix_alignment_heads(folder)
    check_converted(folder)
    assert transcriber.location() == folder
    with open(os.path.join(folder, 'config.json')) as file:
        assert json.load(file)['lang_ids'] == [1], 'the rest of the config is kept'
    assert WhisperTranscriber('large-v3', models_dir=str(tmp_path)).location() == 'large-v3'


def test_heads_are_the_last_decoder_layer():
    assert ANIME_WHISPER_HEADS == [[1, head] for head in range(20)]
    assert 'faster_whisper' not in sys.modules, 'the tests never load the real model'
