from conftest import Word

from kaku.transcript import Segment, resplit, sentences, vtt


def test_hallucinations_are_dropped():
    loop = [Segment(words=[Word('ご視聴ありがとうございました。', i, i + 0.9)]) for i in range(4)]
    silence = Segment(words=[Word('字幕', 10, 10.5), Word('。', 10.5, 10.6)], no_speech_prob=0.9, avg_logprob=-1.5)
    real = Segment(words=[Word('本題', 20, 20.5), Word('です。', 20.5, 21)])
    result = sentences(loop + [silence, real])
    assert [s['text'] for s in result] == ['ご視聴ありがとうございました。', '本題です。']


def test_repetitive_segments_lower_confidence():
    result = sentences([Segment(words=[Word('はい', 0, 0.5, 0.8), Word('。', 0.5, 0.6, 0.8)], compression_ratio=3.0)])
    assert result[0]['confidence'] == 0.4


def test_vtt_stamps():
    text = vtt({'sentences': [{'start': 3725.5, 'end': 3727.25, 'text': 'こんにちは。'}]})
    assert text == 'WEBVTT\n\n01:02:05.500 --> 01:02:07.250\nこんにちは。\n'


def test_the_prompt_leaking_into_the_text_is_dropped():
    leak = Segment(words=[Word('そうですね、', 0, 0.5), Word('楽しみです！', 0.5, 1.0)])
    real = Segment(words=[Word('楽しみです', 2, 2.5), Word('ね。', 2.5, 3.0)])
    result = sentences([leak, real], prompt='こんにちは。そうですね、楽しみです！')
    assert [s['text'] for s in result] == ['楽しみですね。']


def test_resplit_joins_a_word_cut_by_an_old_split():
    def line(text_words, confidence):
        ws = [{'text': t, 'start': a, 'end': b, 'confidence': 1.0} for t, a, b in text_words]
        return {'start': ws[0]['start'], 'end': ws[-1]['end'], 'text': ''.join(t for t, _, _ in text_words),
                'confidence': confidence, 'words': ws}
    old = {'item': {}, 'source': {'fingerprint': 'f'}, 'sentences': [
        line([('安い', 28.5, 28.9), ('なら、', 28.9, 29.08), ('遠', 29.26, 30.08)], 1.0),
        line([('慮', 39.42, 39.84), ('なく', 39.84, 40.08), ('する!', 40.74, 40.84)], 1.0),
        line([('はい', 50.0, 50.5), ('。', 50.5, 50.6)], 0.5)]}
    new = resplit(old)
    assert [s['text'] for s in new['sentences']] == ['安いなら、遠慮なくする!', 'はい。']
    assert new['source'] == old['source'] and new['sentences'][1]['confidence'] == 0.5
    assert resplit(new) is None
