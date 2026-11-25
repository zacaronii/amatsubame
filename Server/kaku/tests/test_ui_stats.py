import json
import os
import time
from dataclasses import replace

from fastapi.testclient import TestClient

from conftest import NOW

from kaku.api import create_app
from kaku.ui import csrf_token

SECRET = 'ui-secret'
AUTH = {'Authorization': 'Bearer secret-token'}
BROWSER = {'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'}


def client(service, secret=SECRET):
    service.config = replace(service.config, ui_secret=secret)
    return TestClient(create_app(service), follow_redirects=False)


def proxy():
    return {'X-Kaku-UI': SECRET, 'X-authentik-username': 'owner', 'X-CSRF-Token': csrf_token(SECRET, 'owner')}


# The bare address

def test_a_browser_at_the_bare_address_goes_to_the_page(service):
    answer = client(service).get('/', headers=BROWSER)
    assert answer.status_code == 302 and answer.headers['location'] == 'ui', 'relative: works under any proxy path'


def test_no_page_no_redirect(service):
    assert client(service, secret='').get('/', headers=BROWSER).status_code == 404


def test_api_clients_see_no_change(service):
    api = client(service)
    for headers in ({}, {'Accept': 'application/json'}, {'Accept': '*/*'}, AUTH):
        answer = api.get('/', headers=headers)
        assert answer.status_code == 404 and answer.json() == {'detail': 'Not Found'}, headers
    assert api.head('/', headers=BROWSER).status_code == 404, 'HEAD as before'
    assert api.get('/health').status_code == 200


# Stats

def test_history_is_kept_as_jobs_finish(service):
    api = client(service)
    api.put('/libraries', headers=AUTH, json={'enabled': ['lib-1']})
    service.poller.poll_once(now=NOW)
    assert service.worker.run_once() is True
    rows = service.db.history()
    assert len(rows) == 1 and rows[0]['library_id'] == 'lib-1' and rows[0]['duration'] > 0
    assert rows[0]['seconds'] is not None and rows[0]['model'].startswith('large-v3/')


def test_the_stats_page(service):
    api = client(service)
    service.db.sync_libraries([{'id': 'lib-1', 'name': 'Podcasts', 'mediaType': 'podcast'}])
    now = time.time()
    job = {'item_id': 'i', 'episode_id': 'e', 'library_id': 'lib-1', 'fingerprint': 'f'}
    # Two hours of audio yesterday in 10 minutes each (12× real time); half an hour today.
    for index in range(2):
        service.db.finish(job | {'episode_id': f'e{index}'}, '/x.json', 'anime-whisper/p2', now=now - 86400,
                          duration=3600, seconds=300)
    service.db.finish(job | {'episode_id': 'e9'}, '/x.json', 'anime-whisper/p2', now=now, duration=1800, seconds=150)
    page = api.get('/ui/stats', headers=proxy())
    assert page.status_code == 200 and 'data-view="stats"' in page.text
    assert 'Last 30 days: 2.5 h of audio' in page.text
    assert '<meter min="0" max="2.000" value="2.000">' in page.text and '<td>0.5 h</td>' in page.text
    assert '<td>Podcasts</td><td>2.5 h</td>' in page.text
    assert 'anime-whisper' in page.text and '12× real time' in page.text and 'about 5 min per hour of audio' in page.text
    assert api.get('/ui/stats').status_code == 403
    assert 'href="/ui/stats"' in api.get('/ui', headers=proxy()).text
    assert api.get('/ui/sections?view=stats', headers=proxy()).text.startswith('<section id="stats">')


def test_the_stats_page_with_nothing_yet(service):
    page = client(service).get('/ui/stats', headers=proxy()).text
    assert 'Last 30 days: 0.0 h of audio' in page and 'Nothing transcribed yet.' in page and 'Not timed yet.' in page


def test_transcripts_from_before_are_counted_once(service, tmp_path):
    db = service.db
    db.execute('DELETE FROM history')
    db.set_meta('history_backfilled', '')
    path = tmp_path / 'book.json'
    path.write_text(json.dumps({'item': {'libraryId': 'lib-2'}, 'source': {'duration': 7200}}), encoding='utf-8')
    db.execute('INSERT INTO transcript (item_id, episode_id, path, fingerprint, model, created_at) VALUES (?, ?, ?, ?, ?, ?)',
               ('book-1', '', str(path), 'f', 'large-v3/p2', NOW))
    db.execute('INSERT INTO transcript (item_id, episode_id, path, fingerprint, model, created_at) VALUES (?, ?, ?, ?, ?, ?)',
               ('gone', '', str(tmp_path / 'missing.json'), 'f', 'large-v3/p2', NOW))
    assert db.backfill_history() == 1, 'a missing file is skipped'
    assert db.history()[0]['library_id'] == 'lib-2' and db.history()[0]['duration'] == 7200 and db.history()[0]['seconds'] is None
    assert db.backfill_history() == 0, 'only once'
    assert db.speed() == {}, 'backfilled lines without times don’t count for speed'
