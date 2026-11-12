import pytest
from fastapi.testclient import TestClient

from conftest import fixture

from kaku.api import create_app
from kaku.jellyfin import NoJapaneseAudio, episode_from
from kaku.worker import JELLYFIN_PROMPT

AUTH = {'Authorization': 'Bearer secret-token'}


def client(service):
    return TestClient(create_app(service))


def test_the_japanese_track_is_chosen():
    episode = episode_from(fixture('jellyfin-anime.json')['Items'][0])
    # An external English subtitle is listed first; the file's audio is Japanese, then English.
    assert episode.audio_track == 0
    assert episode.item_id == 'jf:jf-anime-1' and episode.episode_id == '' and episode.library_id == 'jellyfin'
    assert episode.title == 'テストアニメ S1E3 第3話'
    assert episode.fingerprint.startswith('source-anime-1:1500000000:')
    assert episode.duration > 0


def test_english_only_audio_is_refused():
    with pytest.raises(NoJapaneseAudio):
        episode_from(fixture('jellyfin-english.json')['Items'][0])


def test_untagged_audio_counts_as_the_original():
    item = fixture('jellyfin-english.json')['Items'][0]
    for stream in item['MediaSources'][0]['MediaStreams']:
        if stream['Type'] == 'Audio':
            stream['Language'] = None
    assert episode_from(item).audio_track == 0


def test_transcribe_on_request_then_srt(service):
    api = client(service)
    assert api.get('/health').json()['jellyfin'] is True
    assert api.get('/jellyfin/transcripts/jf-anime-1', headers=AUTH).status_code == 404
    answer = api.post('/jellyfin/jobs', headers=AUTH, json={'itemIds': ['jf-anime-1', 'jf-english-1', 'gone']}).json()['jobs']
    assert [(a['itemId'], a['state']) for a in answer] == [
        ('jf-anime-1', 'queued'), ('jf-english-1', 'unavailable'), ('gone', 'unavailable')]
    assert answer[0]['position'] == 0
    assert 'Japanese' in answer[1]['error']
    waiting = api.get('/jellyfin/transcripts/jf-anime-1', headers=AUTH)
    assert waiting.status_code == 202 and waiting.json()['state'] == 'queued'

    assert service.worker.run_once()
    # The Japanese track straight from Jellyfin, with the key only in ffmpeg's headers.
    command = service.commands[-1]
    assert command[command.index('-map') + 1] == '0:a:0'
    assert command[command.index('-i') + 1] == 'http://jellyfin.test/Videos/jf-anime-1/stream?static=true&mediaSourceId=source-anime-1'
    assert 'jellyfin-key' in command[command.index('-headers') + 1]
    assert service.transcriber.prompts == [JELLYFIN_PROMPT]

    assert api.post('/jellyfin/transcripts/status', headers=AUTH,
                    json={'itemIds': ['jf-anime-1', 'jf-english-1']}).json()['statuses'] == {
        'jf-anime-1': 'done', 'jf-english-1': 'missing'}
    subtitles = api.get('/jellyfin/transcripts/jf-anime-1?format=srt', headers=AUTH)
    assert subtitles.status_code == 200
    assert subtitles.text.startswith('1\n00:00:00,000 --> 00:00:01,000\n今日は晴れ。\n\n2\n')
    document = api.get('/jellyfin/transcripts/jf-anime-1', headers=AUTH).json()
    assert document['item'] == {'libraryItemId': 'jf:jf-anime-1', 'episodeId': '', 'libraryId': 'jellyfin'}
    assert api.get('/jellyfin/transcripts/jf-anime-1?format=vtt', headers=AUTH).text.startswith('WEBVTT')
    # Asked again: already done, nothing queued.
    assert api.post('/jellyfin/jobs', headers=AUTH, json={'itemIds': ['jf-anime-1']}).json()['jobs'][0]['state'] == 'done'
    assert not service.worker.run_once()


def test_jellyfin_routes_need_the_token_and_a_server(service):
    api = client(service)
    assert api.post('/jellyfin/jobs', json={'itemIds': ['jf-anime-1']}).status_code == 401
    assert api.get('/jellyfin/transcripts/jf-anime-1').status_code == 401
    assert api.post('/jellyfin/jobs', headers=AUTH, json={'itemIds': []}).status_code == 400
    service.jellyfin = None
    assert api.post('/jellyfin/jobs', headers=AUTH, json={'itemIds': ['jf-anime-1']}).status_code == 503


def test_a_failed_read_keeps_the_key_out_of_the_error(service, monkeypatch):
    import subprocess

    def failing(command, check=False, **kwargs):
        raise subprocess.CalledProcessError(1, command, stderr=b'Server returned 404 Not Found')
    monkeypatch.setattr('kaku.worker.subprocess.run', failing)
    client(service).post('/jellyfin/jobs', headers=AUTH, json={'itemIds': ['jf-anime-1']})
    service.worker.run_once()
    job = service.db.job('jf:jf-anime-1', '')
    assert 'jellyfin-key' not in job['error'] and '404 Not Found' in job['error']
