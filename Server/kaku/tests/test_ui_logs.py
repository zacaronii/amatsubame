import logging
import threading
import time
from dataclasses import replace

from fastapi.testclient import TestClient

from conftest import NOW

from kaku import logs
from kaku.api import create_app
from kaku.logs import JobLog, Redactor
from kaku.ui import csrf_token
from kaku.worker import Gone

SECRET = 'ui-secret'
AUTH = {'Authorization': 'Bearer secret-token'}


def setup(service):
    service.config = replace(service.config, ui_secret=SECRET)
    api = TestClient(create_app(service))
    api.put('/libraries', headers=AUTH, json={'enabled': ['lib-1']})
    service.poller.poll_once(now=NOW)
    headers = {'X-Kaku-UI': SECRET, 'X-authentik-username': 'owner', 'Origin': 'http://testserver',
               'X-CSRF-Token': csrf_token(SECRET, 'owner')}
    return api, headers


def act(api, headers, action, job):
    return api.post('/ui/api/action', headers=headers,
                    json={'action': action, 'itemId': job['item_id'], 'episodeId': job['episode_id']})


def test_cancel_now_stops_the_running_job(service):
    api, headers = setup(service)
    gate = threading.Event()
    service.transcriber.gate = gate
    worker = threading.Thread(target=service.worker.run_once)
    worker.start()
    for _ in range(200):
        if service.worker.current is not None:
            break
        time.sleep(0.01)
    running = service.worker.current
    assert running is not None
    queued = service.db.queue()[-1]
    assert act(api, headers, 'cancel-now', queued).status_code == 409, 'only the running job'
    assert act(api, headers, 'cancel-now', running).status_code == 200
    gate.set()
    worker.join(5)
    job = service.db.job(running['item_id'], running['episode_id'])
    assert job['state'] == 'cancelled' and service.db.transcript(running['item_id'], running['episode_id']) is None
    assert service.worker.current is None and not service.worker.cancelling.is_set()
    assert service.db.changes()[0]['action'] == 'cancel-now'
    # The next job runs as usual.
    service.transcriber.gate = None
    assert service.worker.run_once() is True
    assert service.db.counts().get('done') == 1


def test_a_failed_jobs_log_is_kept_without_keys(service, monkeypatch):
    api, headers = setup(service)

    def gone(*args, **kwargs):
        logging.getLogger('kaku.worker').info('fetching with secret-token')
        raise Gone('Audiobookshelf refused secret-token')
    monkeypatch.setattr(service.transcriber, 'transcribe', gone)
    root = logging.getLogger()
    level = root.level
    root.setLevel(logging.INFO)  # as Kaku runs (main: basicConfig at INFO)
    try:
        assert service.worker.run_once() is True
    finally:
        root.setLevel(level)
    failed = service.db.failed()[0]
    saved = service.db.job_log(failed['item_id'], failed['episode_id'])
    assert saved and 'fetching with •••' in saved['text'] and 'secret-token' not in saved['text']
    page = api.get('/ui', headers=headers).text
    assert 'href="/ui/log?item=' in page
    shown = api.get(f'/ui/log?item={failed["item_id"]}&episode={failed["episode_id"]}', headers=headers)
    assert shown.status_code == 200 and 'fetching with •••' in shown.text and 'secret-token' not in shown.text
    assert api.get(f'/ui/log?item={failed["item_id"]}&episode={failed["episode_id"]}').status_code == 403
    assert api.get('/ui/log?item=nope&episode=nope', headers=headers).status_code == 404


def test_logs_are_kept_14_days(service):
    db = service.db
    db.save_log('old', 'e', 'old lines', now=NOW - 15 * 86400)
    assert db.job_log('old', 'e', now=NOW) is None, 'past 14 days it isn’t shown'
    db.save_log('new', 'e', 'new lines', now=NOW)
    assert db.execute("SELECT COUNT(*) AS n FROM job_log WHERE item_id = 'old'")[0]['n'] == 0, 'and is deleted'
    assert db.job_log('new', 'e', now=NOW + 13 * 86400)['text'] == 'new lines'


def test_the_log_tail_takes_keys_out(service):
    api, headers = setup(service)
    logs.install(['secret-token', SECRET])
    try:
        logging.getLogger('kaku.test').warning('header <Authorization: Bearer secret-token> and %s', SECRET)
        page = api.get('/ui/logs', headers=headers).text
        assert 'kaku.test WARNING header &lt;Authorization: Bearer •••&gt; and •••' in page
        assert 'secret-token' not in page and 'ui-secret' not in page
    finally:
        logging.getLogger().removeHandler(logs.RING)


def test_a_jobs_log_has_only_its_own_threads_lines():
    root = logging.getLogger()
    level = root.level
    root.setLevel(logging.INFO)
    try:
        with JobLog(Redactor(['hidden-key'])) as lines:
            logging.getLogger('kaku.worker').info('mine, with hidden-key')
            other = threading.Thread(target=lambda: logging.getLogger('kaku.poller').info('not mine'))
            other.start()
            other.join()
        assert 'mine, with •••' in lines.text() and 'not mine' not in lines.text()
        assert lines not in root.handlers, 'removed afterwards'
    finally:
        root.setLevel(level)


def test_redactor_ignores_short_or_empty_values():
    redact = Redactor(['', 'key', 'long-secret'])
    assert redact('key long-secret') == 'key •••'


def test_redactor_catches_a_secret_in_a_url():
    redact = Redactor(['a/b+c d=e&f'])
    assert redact('GET https://abs.example/api?token=a%2Fb%2Bc%20d%3De%26f failed') == 'GET https://abs.example/api?token=••• failed'
    assert redact('token=a%2Fb%2Bc+d%3De%26f') == 'token=•••'
    assert redact('raw a/b+c d=e&f') == 'raw •••'
    assert redact('/items/a/b%2Bc%20d%3De%26f') == '/items/•••', 'quoted as a path, / kept'
