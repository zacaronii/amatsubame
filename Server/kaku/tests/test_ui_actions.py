from dataclasses import replace

from fastapi.testclient import TestClient

from conftest import NOW

from kaku.api import create_app
from kaku.db import NOW as ASKED
from kaku.ui import csrf_token

SECRET = 'ui-secret'
AUTH = {'Authorization': 'Bearer secret-token'}


def setup(service):
    """The page's client with Podcasts on and its episodes queued; and the headers a change needs."""
    service.config = replace(service.config, ui_secret=SECRET)
    api = TestClient(create_app(service))
    api.put('/libraries', headers=AUTH, json={'enabled': ['lib-1']})
    service.poller.poll_once(now=NOW)
    headers = {'X-Kaku-UI': SECRET, 'X-authentik-username': 'owner', 'Origin': 'http://testserver',
               'X-CSRF-Token': csrf_token(SECRET, 'owner')}
    return api, headers


def act(api, headers, action, job=None, **extra):
    body = {'action': action, **({'itemId': job['item_id'], 'episodeId': job['episode_id']} if job else {}), **extra}
    return api.post('/ui/api/action', headers=headers, json=body)


def order(service):
    return [(job['item_id'], job['episode_id']) for job in service.db.queue()]


def test_changes_need_the_pages_token_and_origin(service):
    api, headers = setup(service)
    job = service.db.queue()[-1]
    for missing in ('X-CSRF-Token', 'Origin', 'X-Kaku-UI'):
        without = {name: value for name, value in headers.items() if name != missing}
        assert act(api, without, 'next', job).status_code == 403, missing
    assert act(api, headers | {'X-CSRF-Token': csrf_token(SECRET, 'someone else')}, 'next', job).status_code == 403
    assert act(api, headers | {'Origin': 'https://elsewhere.example'}, 'next', job).status_code == 403
    # Behind the proxy the page's address is the forwarded host.
    proxied = headers | {'Origin': 'https://kaku.example', 'X-Forwarded-Host': 'kaku.example'}
    assert act(api, proxied, 'next', job).status_code == 200
    assert service.db.changes() and service.db.changes()[0]['user'] == 'owner'


def test_next_moves_a_job_to_the_front(service):
    api, headers = setup(service)
    last = service.db.queue()[-1]
    answer = act(api, headers, 'next', last)
    assert answer.status_code == 200 and answer.text.startswith('<section id="status">')
    assert order(service)[0] == (last['item_id'], last['episode_id'])
    assert service.db.job(last['item_id'], last['episode_id'])['priority'] == ASKED
    assert service.worker.wake.is_set()


def test_cancel_keeps_it_out_until_asked_for(service):
    api, headers = setup(service)
    job = service.db.queue()[0]
    key = (job['item_id'], job['episode_id'])
    assert act(api, headers, 'cancel', job).status_code == 200
    assert key not in order(service)
    service.poller.poll_once(now=NOW + 600)
    assert key not in order(service), "the poller doesn't queue it again"
    # The apps see it as missing, and asking for it queues it again.
    status = api.post('/transcripts/status', headers=AUTH, json={'episodes': [{'itemId': key[0], 'episodeId': key[1]}]})
    assert status.json()['statuses'][f'{key[0]}/{key[1]}'] == 'missing'
    assert api.get(f'/transcripts/{key[0]}/{key[1]}', headers=AUTH).status_code == 404
    assert api.post('/jobs', headers=AUTH, json={'itemId': key[0], 'episodeId': key[1]}).status_code == 202
    assert order(service)[0] == key


def test_retry_a_failure_or_a_cancelled_job(service):
    api, headers = setup(service)
    job = service.db.queue()[-1]
    service.db.fail(job | {'attempts': 3}, 'gone wrong', now=NOW, permanent=True)
    assert act(api, headers, 'retry', job).status_code == 200
    again = service.db.job(job['item_id'], job['episode_id'])
    assert again['state'] == 'queued' and again['attempts'] == 0 and again['error'] is None and again['priority'] == ASKED
    act(api, headers, 'cancel', again)
    assert act(api, headers, 'retry', again).status_code == 200
    assert service.db.job(job['item_id'], job['episode_id'])['state'] == 'queued'


def test_a_job_that_moved_on_is_a_conflict(service):
    api, headers = setup(service)
    job = service.db.queue()[0]
    assert act(api, headers, 'retry', job).status_code == 409, 'only failed or cancelled jobs are tried again'
    service.db.claim(now=NOW + 10**9)
    running = service.db.job(job['item_id'], job['episode_id'])
    assert running['state'] == 'running'
    assert act(api, headers, 'cancel', running).status_code == 409, 'cancelling the running job is milestone 3'
    assert act(api, headers, 'next', {'item_id': 'nope', 'episode_id': 'nope'}).status_code == 404
    assert act(api, headers, 'shrug').status_code == 400


def test_libraries_switch_from_the_page(service):
    api, headers = setup(service)
    assert act(api, headers, 'library-on', libraryId='lib-2').status_code == 200
    assert {l['id'] for l in service.db.libraries() if l['enabled']} == {'lib-1', 'lib-2'}
    assert act(api, headers, 'library-off', libraryId='lib-1').status_code == 200
    assert not [job for job in service.db.queue() if job['library_id'] == 'lib-1']
    assert act(api, headers, 'library-on', libraryId='nope').status_code == 404
    assert [change['action'] for change in service.db.changes()] == ['library-off', 'library-on']


def test_stop_after_this_one_and_resume(service):
    api, headers = setup(service)
    assert act(api, headers, 'pause').status_code == 200
    assert service.db.paused and api.get('/health').json()['paused']
    assert service.worker.run_once() is False, 'nothing new starts'
    assert order(service), 'the queue is kept'
    page = api.get('/ui', headers=headers).text
    assert 'Resume the queue' in page and 'Stopped' in page
    service.worker.wake.clear()
    assert act(api, headers, 'resume').status_code == 200
    assert not service.db.paused and service.worker.wake.is_set()
    assert service.worker.run_once() is True


def test_poll_now_wakes_the_poller(service):
    api, headers = setup(service)
    service.poller.wake.clear()
    assert act(api, headers, 'poll').status_code == 200
    assert service.poller.wake.is_set()


def test_the_page_shows_its_buttons_and_who_changed_what(service):
    api, headers = setup(service)
    job = service.db.queue()[-1]
    act(api, headers, 'next', job)
    page = api.get('/ui', headers=headers).text
    assert 'data-action="cancel"' in page and 'data-action="library-off"' in page and 'data-action="poll"' in page
    assert 'Recent changes' in page and f'next · {job["title"]}' in page and '>owner · ' in page
    assert ' on' + 'click' not in page, 'no inline handlers (the CSP forbids them)'
