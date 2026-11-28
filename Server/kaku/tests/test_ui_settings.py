import json
import os
from dataclasses import replace

from fastapi.testclient import TestClient

from conftest import NOW, FakeAudiobookshelf, FakeJellyfin, FakeTranscriber

from kaku.api import create_app
from kaku.main import build
from kaku.pipeline import ANIME_WHISPER_FOLDER, ANIME_WHISPER_HEADS
from kaku.ui import csrf_token

SECRET = 'ui-secret'
AUTH = {'Authorization': 'Bearer secret-token'}


def setup(service, models_dir=None):
    service.config = replace(service.config, ui_secret=SECRET, models_dir=models_dir or service.config.models_dir)
    api = TestClient(create_app(service))
    headers = {'X-Kaku-UI': SECRET, 'X-authentik-username': 'owner', 'Origin': 'http://testserver',
               'X-CSRF-Token': csrf_token(SECRET, 'owner')}
    return api, headers


def change(api, headers, key, value=None, action='setting'):
    return api.post('/ui/api/action', headers=headers,
                    json={'action': action, 'key': key, 'value': value or '', 'view': 'settings'})


def converted(folder):
    """A made-up anime-whisper conversion: the files check_converted looks at."""
    os.makedirs(os.path.join(folder, ANIME_WHISPER_FOLDER))
    for name in ('model.bin', 'tokenizer.json'):
        open(os.path.join(folder, ANIME_WHISPER_FOLDER, name), 'w').close()
    with open(os.path.join(folder, ANIME_WHISPER_FOLDER, 'config.json'), 'w') as file:
        json.dump({'alignment_heads': ANIME_WHISPER_HEADS}, file)
    return folder


def test_the_settings_page(service):
    api, headers = setup(service)
    page = api.get('/ui/settings', headers=headers)
    assert page.status_code == 200 and 'data-view="settings"' in page.text
    for label in ('Model', 'Chunk length', 'Prompt', 'New for', 'Check Audiobookshelf every', 'Unload the model'):
        assert label in page.text
    assert 'from the environment' in page.text and 'set here' not in page.text
    assert 'secret-token' not in page.text and 'abs.test' not in page.text, 'no keys or addresses on the page'
    assert api.get('/ui/settings').status_code == 403
    assert 'href="/ui/settings"' in api.get('/ui', headers=headers).text


def test_a_live_setting_applies_at_once_and_resets(service):
    api, headers = setup(service)
    service.poller.wake.clear()
    answer = change(api, headers, 'poll_seconds', '900')
    assert answer.status_code == 200 and answer.text.startswith('<section id="settings">') and 'set here' in answer.text
    assert service.poller.poll_seconds == 900 and service.poller.wake.is_set()
    assert service.db.settings() == {'poll_seconds': '900'}
    assert service.db.changes()[0]['detail'] == 'Check Audiobookshelf every (seconds): 900'
    change(api, headers, 'idle_unload_seconds', '0')
    assert service.worker.idle_unload_seconds == 0
    change(api, headers, 'new_days', '30')
    assert service.poller.new_days == 30
    assert change(api, headers, 'poll_seconds', action='setting-reset').status_code == 200
    assert service.poller.poll_seconds == service.config.poll_seconds and 'poll_seconds' not in service.db.settings()


def test_values_are_checked(service):
    api, headers = setup(service)
    assert change(api, headers, 'poll_seconds', '10').status_code == 400, 'below the minimum'
    assert change(api, headers, 'chunk_length', 'fifteen').status_code == 400
    assert change(api, headers, 'chunk_length', '31').status_code == 400
    assert change(api, headers, 'prompt', 'あ' * 301).status_code == 400
    assert change(api, headers, 'models_dir', '/tmp').status_code == 400, 'paths stay in the environment'
    assert change(api, headers, 'api_token', 'x').status_code == 400
    assert change(api, headers, 'model', 'whisper-tiny-made-up').status_code == 400
    assert service.db.settings() == {}


def test_the_prompt_keeps_the_environments_meaning(service):
    api, headers = setup(service)
    change(api, headers, 'prompt', 'none')
    assert service.transcriber.prompt == '', 'none: no prompt'
    change(api, headers, 'prompt', '')
    assert service.transcriber.prompt is None, "empty: the model's default"
    change(api, headers, 'prompt', '句読点を付けてください。')
    assert service.transcriber.prompt == '句読点を付けてください。'
    change(api, headers, 'chunk_length', '20')
    assert service.transcriber.chunk_length == 20


def test_switching_the_model_waits_for_the_next_job_and_redoes_nothing(service):
    api, headers = setup(service)
    api.put('/libraries', headers=AUTH, json={'enabled': ['lib-1']})
    service.poller.poll_once(now=NOW)
    assert service.worker.run_once() is True
    done_before = service.db.counts().get('done')
    service.transcriber.loaded = True
    assert change(api, headers, 'model', 'large-v3-turbo').status_code == 200
    assert service.transcriber.name == 'large-v3', 'the job running keeps its model'
    assert 'Switching to large-v3-turbo at the next job' in api.get('/ui/settings', headers=headers).text
    service.worker.run_once()
    assert service.transcriber.name == 'large-v3-turbo' and service.poller.model == 'large-v3-turbo'
    assert service.db.counts().get('done') >= done_before
    service.db.execute("DELETE FROM job WHERE state = 'queued'")
    service.poller.poll_once(now=NOW + 600)
    assert not [job for job in service.db.queue() if service.db.transcript(job['item_id'], job['episode_id'])], \
        'nothing already transcribed is queued again'


def test_anime_whisper_needs_its_conversion(service, tmp_path):
    api, headers = setup(service, models_dir=str(tmp_path / 'empty'))
    refused = change(api, headers, 'model', 'anime-whisper')
    assert refused.status_code == 400 and 'kaku.convert' in refused.json()['detail']
    checked = api.post('/ui/api/action', headers=headers, json={'action': 'check-model', 'value': 'anime-whisper', 'view': 'settings'})
    assert checked.status_code == 200 and 'kaku.convert' in checked.text and 'class="problem"' in checked.text
    api, headers = setup(service, models_dir=converted(str(tmp_path / 'models')))
    page = api.get('/ui/settings', headers=headers).text
    assert '>anime-whisper</option>' in page and 'large-v3 (downloads on first use)' in page
    assert change(api, headers, 'model', 'anime-whisper').status_code == 200
    checked = api.post('/ui/api/action', headers=headers, json={'action': 'check-model', 'value': 'anime-whisper', 'view': 'settings'})
    assert 'converted and ready' in checked.text


def test_settings_from_the_page_win_at_the_next_start(service):
    api, headers = setup(service)
    change(api, headers, 'poll_seconds', '1200')
    change(api, headers, 'model', 'large-v3-turbo')
    change(api, headers, 'chunk_length', '20')
    again = build(service.config, transcriber=FakeTranscriber(), audiobookshelf=FakeAudiobookshelf(), jellyfin=FakeJellyfin())
    assert again.poller.poll_seconds == 1200 and again.transcriber.chunk_length == 20
    assert again.transcriber.name == 'large-v3-turbo' and again.worker.next_model is None
    assert TestClient(create_app(again)).get('/health').json()['model'] == 'large-v3-turbo'
