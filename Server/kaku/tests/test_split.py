from kaku.split import Word, repeated, split


def words(*items):
    return [Word(text, start, end) for text, start, end in items]


def test_splits_at_sentence_enders():
    sentences = split(words(('今日', 0.0, 0.4), ('は', 0.4, 0.5), ('晴れ', 0.5, 0.9), ('。', 0.9, 1.0),
                            ('明日', 1.1, 1.5), ('も', 1.5, 1.6), ('？', 1.6, 1.7)))
    assert [s.text for s in sentences] == ['今日は晴れ。', '明日も？']
    assert (sentences[1].start, sentences[1].end) == (1.1, 1.7)


def test_splits_at_long_pauses():
    sentences = split(words(('そう', 0.0, 0.3), ('です', 0.3, 0.6), ('か', 2.0, 2.2), ('なあ', 2.2, 2.5)))
    assert [s.text for s in sentences] == ['そうです', 'かなあ']


def test_long_pauses_dont_split_a_word():
    # Whisper can put 9 s between the kanji of one word (遠慮 here), and 0.9 s between a number and 円.
    sentences = split(words(('もしも', 25.7, 28.4), ('安い', 28.5, 28.9), ('なら、', 28.9, 29.08), ('遠', 29.26, 30.08),
                            ('慮', 39.42, 39.84), ('なく', 39.84, 40.08), ('注文', 40.08, 40.74), ('する!', 40.74, 40.84),
                            ('50', 41.0, 41.76), ('円', 42.63, 43.13), ('残った', 43.13, 43.57), ('ら、', 43.57, 43.67)))
    assert [s.text for s in sentences] == ['もしも安いなら、', '遠慮なく注文する!', '50円残ったら、']


def test_long_pauses_dont_start_a_line_with_wo():
    # A narrator pausing 3 s between 手 and を.
    sentences = split(words(('見る', 18.56, 19.0), ('と、', 19.0, 19.4), ('手', 19.48, 20.38),
                            ('を', 23.48, 23.8), ('振', 23.8, 24.14), ('られた。', 24.14, 24.5)))
    assert [s.text for s in sentences] == ['見ると、手を振られた。']


def test_a_pause_after_a_word_still_splits():
    sentences = split(words(('そう', 0.0, 0.3), ('です', 0.3, 0.6), ('今日', 2.0, 2.4), ('は', 2.4, 2.5)))
    assert [s.text for s in sentences] == ['そうです', '今日は']


def test_a_very_long_pause_splits_even_between_kanji():
    sentences = split(words(('応', 0.0, 0.3), ('募', 0.3, 0.6), ('週', 30.0, 30.3), ('間', 30.3, 30.6)))
    assert [s.text for s in sentences] == ['応募', '週間']


def test_short_pauses_and_blank_words_dont_split():
    sentences = split(words(('えっと', 0.0, 0.4), (' ', 0.4, 0.5), ('はい', 0.9, 1.1)))
    assert [s.text for s in sentences] == ['えっとはい']


def test_long_lines_are_cut_at_the_longest_pause():
    # 20 s of speech with one clear breath at 9 s: cut there, nowhere else.
    items = [('あ', i * 0.5, i * 0.5 + 0.45) for i in range(18)]
    items += [('い', 9.5 + i * 0.5, 9.5 + i * 0.5 + 0.45) for i in range(21)]
    sentences = split(words(*items))
    assert [round(s.start, 2) for s in sentences] == [0.0, 9.5]
    assert all(s.duration <= 15 for s in sentences)


def test_long_lines_prefer_clause_endings():
    # Even gaps everywhere; the line is cut after けど, not in the middle of a word run.
    items = [('話', i * 0.5, i * 0.5 + 0.4) for i in range(10)] + [('けど', 5.0, 5.4)]
    items += [('続き', 5.5 + i * 0.5, 5.5 + i * 0.5 + 0.4) for i in range(25)]
    sentences = split(words(*items))
    assert sentences[0].text.endswith('けど')
    assert all(s.duration <= 15 for s in sentences)


def test_endless_speech_is_cut_to_the_limit():
    long = [Word('あ', i * 1.0, i * 1.0 + 0.5) for i in range(100)]
    sentences = split(long, max_length=15)
    assert len(sentences) > 1
    assert all(s.duration <= 15 for s in sentences)


def test_one_word_fragments_join_the_nearer_neighbour():
    sentences = split(words(('そう', 0.0, 0.3), ('です', 0.3, 0.6), ('ね', 1.5, 1.7),
                            ('次', 5.0, 5.3), ('の', 5.3, 5.4), ('話', 5.4, 5.8)))
    assert [s.text for s in sentences] == ['そうですね', '次の話']


def test_one_word_sentences_that_end_stay():
    sentences = split(words(('はい。', 0.0, 0.5), ('そう', 2.0, 2.3), ('です', 2.3, 2.6), ('。', 2.6, 2.7)))
    assert [s.text for s in sentences] == ['はい。', 'そうです。']


def test_repeated_lines_are_flagged():
    sentences = split(words(('はい。', 0, 1), ('ご視聴ありがとうございました。', 1, 2), ('ご視聴ありがとうございました。', 2, 3),
                            ('ご視聴ありがとうございました。', 3, 4), ('では。', 4, 5)))
    assert repeated(sentences) == {2, 3}
    assert repeated(sentences[:3]) == set()
