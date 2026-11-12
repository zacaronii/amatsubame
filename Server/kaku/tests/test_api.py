import threading

from fastapi.testclient import TestClient

from conftest import NOW

from kaku.api import create_app

AUTH = {'Authorization': 'Bearer secret-token'}


def client(service):
    return TestClient(create_app(service))


def test_everything_but_health_needs_the_token(service):
    api = client(service)
    assert api.get('/health').status_code == 200
    for method, path in (('get', '/jobs'), ('get', '/libraries'), ('get', '/transcripts/item-1/episode-1')):
        assert getattr(api, method)(path).status_code == 401
        assert getattr(api, method)(path, headers={'Authorization': 'Bearer wrong'}).status_code == 401
    assert api.post('/jobs', json={'itemId': 'item-1', 'episodeId': 'episode-1'}).status_code == 401
    assert api.post('/transcripts/status', json={'episodes': []}).status_code == 401


def test_libraries_switch_on(service):
    api = client(service)
    listed = api.get('/libraries', headers=AUTH).json()['libraries']
    assert {(l['name'], l['mediaType'], l['enabled']) for l in listed} == {
        ('Books', 'book', False), ('Podcasts', 'podcast', False), ('Japanese Books', 'book', False)}
    assert api.put('/libraries', headers=AUTH, json={'enabled': ['nope']}).status_code == 400
    switched = api.put('/libraries', headers=AUTH, json={'enabled': ['lib-1', 'lib-2']}).json()['libraries']
    assert {l['id'] for l in switched if l['enabled']} == {'lib-1', 'lib-2'}


def test_pending_then_done(service):
    api = client(service)
    api.put('/libraries', headers=AUTH, json={'enabled': ['lib-1']})
    assert api.get('/transcripts/item-1/episode-1', headers=AUTH).status_code == 404
    service.poller.poll_once(now=NOW)
    pending = api.get('/transcripts/item-1/episode-2', headers=AUTH)
    assert pending.status_code == 202
    assert pending.json()['state'] == 'queued' and pending.json()['position'] == 1 and pending.json()['priority'] == 'backlog'
    service.worker.run_once()
    done = api.get('/transcripts/item-1/episode-1', headers=AUTH)
    assert done.status_code == 200 and done.json()['sentences'][0]['text'] == '今日は晴れ。'
    assert api.get('/transcripts/item-1/episode-1?format=vtt', headers=AUTH).text.startswith('WEBVTT')


def test_post_jobs_jumps_the_queue(service):
    api = client(service)
    api.put('/libraries', headers=AUTH, json={'enabled': ['lib-1']})
    service.poller.poll_once(now=NOW)
    asked = api.post('/jobs', headers=AUTH, json={'itemId': 'item-1', 'episodeId': 'episode-2'})
    assert asked.status_code == 202 and asked.json()['position'] == 0 and asked.json()['priority'] == 'now'
    queue = api.get('/jobs', headers=AUTH).json()
    assert [job['episodeId'] for job in queue['queued']] == ['episode-2', 'episode-1']
    # While it runs, /jobs shows it with its progress.
    service.transcriber.gate = threading.Event()
    thread = threading.Thread(target=service.worker.run_once)
    thread.start()
    for _ in range(100):
        running = api.get('/jobs', headers=AUTH).json()['running']
        if running and running['progress'] > 0.5:
            break
        threading.Event().wait(0.01)
    assert running['episodeId'] == 'episode-2' and running['state'] == 'running'
    service.transcriber.gate.set()
    thread.join(5)
    again = api.post('/jobs', headers=AUTH, json={'itemId': 'item-1', 'episodeId': 'episode-2'})
    assert again.status_code == 200 and again.json()['state'] == 'done'
    assert api.post('/jobs', headers=AUTH, json={'itemId': 'item-1', 'episodeId': 'missing'}).status_code == 404


def test_status_for_many_episodes(service):
    api = client(service)
    api.put('/libraries', headers=AUTH, json={'enabled': ['lib-1']})
    service.poller.poll_once(now=NOW)
    service.worker.run_once()
    episodes = [{'itemId': 'item-1', 'episodeId': e} for e in ('episode-1', 'episode-2', 'nope')]
    answer = api.post('/transcripts/status', headers=AUTH, json={'episodes': episodes})
    assert answer.status_code == 200
    assert answer.json()['statuses'] == {'item-1/episode-1': 'done', 'item-1/episode-2': 'queued', 'item-1/nope': 'missing'}
    too_many = [{'itemId': 'i', 'episodeId': str(n)} for n in range(2001)]
    assert api.post('/transcripts/status', headers=AUTH, json={'episodes': too_many}).status_code == 400


def test_books_by_item_id(service):
    api = client(service)
    api.put('/libraries', headers=AUTH, json={'enabled': ['lib-2']})
    assert api.get('/transcripts/book-1', headers=AUTH).status_code == 404
    asked = api.post('/jobs', headers=AUTH, json={'itemId': 'book-1'})
    assert asked.status_code == 202 and asked.json()['episodeId'] == '' and asked.json()['priority'] == 'now'
    status = api.post('/transcripts/status', headers=AUTH, json={'episodes': [{'itemId': 'book-1'}]}).json()
    assert status['statuses'] == {'book-1': 'queued'}
    service.worker.run_once()
    assert api.get('/transcripts/book-1', headers=AUTH).json()['sentences'][0]['text'] == '今日は晴れ。'
    assert api.post('/transcripts/status', headers=AUTH, json={'episodes': [{'itemId': 'book-1'}]}).json()['statuses'] == {'book-1': 'done'}


def test_clips_are_cut_from_the_right_file(service, monkeypatch):
    import subprocess
    calls = []

    def fake_ffmpeg(command, **kwargs):
        calls.append(command)
        with open(command[-1], 'wb') as file:
            file.write(b'm4a')
        return subprocess.CompletedProcess(command, 0)
    monkeypatch.setattr('kaku.api.subprocess.run', fake_ffmpeg)
    api = client(service)
    clip = api.get('/clips/book-1?start=2800&end=2806.5', headers=AUTH)
    assert clip.status_code == 200 and clip.content == b'm4a' and clip.headers['content-type'] == 'audio/mp4'
    command = calls[-1]
    assert command[command.index('-i') + 1] == 'http://abs.test/api/items/book-1/file/311', 'the second file'
    assert command[command.index('-ss') + 1] == '99.750' and command[command.index('-t') + 1] == '6.500'
    assert command[command.index('-headers') + 1] == 'Authorization: Bearer key\r\n'
    assert api.get('/clips/item-1/episode-1?start=10&end=14', headers=AUTH).status_code == 200
    for bad in ('start=10&end=5', 'start=-1&end=3', 'start=0&end=61', 'start=9000&end=9005'):
        assert api.get(f'/clips/book-1?{bad}', headers=AUTH).status_code == 400, bad
    assert api.get('/clips/book-1/nope?start=0&end=3', headers=AUTH).status_code == 404
    assert api.get('/clips/book-1?start=0&end=3').status_code == 401


def test_clip_errors_dont_show_the_key(service, monkeypatch):
    import subprocess

    def failing(command, **kwargs):
        raise subprocess.CalledProcessError(1, command, stderr=b'Server returned 404 Not Found')
    monkeypatch.setattr('kaku.api.subprocess.run', failing)
    answer = client(service).get('/clips/item-1/episode-1?start=0&end=3', headers=AUTH)
    assert answer.status_code == 502 and 'key' not in answer.text and '404 Not Found' in answer.text
