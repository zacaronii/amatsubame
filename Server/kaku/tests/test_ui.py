from dataclasses import replace

from fastapi.testclient import TestClient

from conftest import NOW

from kaku.api import create_app
from kaku.ui import ago, csrf_token, csrf_valid

SECRET = 'ui-secret'
PROXY = {'X-Kaku-UI': SECRET, 'X-authentik-username': 'owner'}
PATHS = ('/ui', '/ui/sections', '/ui/static/ui.js', '/ui/static/ui.css')


def client(service, secret=SECRET):
    service.config = replace(service.config, ui_secret=secret)
    return TestClient(create_app(service))


def test_the_page_is_off_without_a_secret(service):
    api = client(service, secret='')
    for path in PATHS:
        assert api.get(path, headers=PROXY).status_code == 404


def test_only_the_proxy_gets_in(service):
    api = client(service)
    for path in PATHS:
        assert api.get(path).status_code == 403, path
        assert api.get(path, headers={'X-Kaku-UI': 'wrong'}).status_code == 403, path
        # The app's bearer token isn't a way in either.
        assert api.get(path, headers={'Authorization': 'Bearer secret-token'}).status_code == 403, path
        assert api.get(path, headers=PROXY).status_code == 200, path


def test_the_bearer_api_is_unchanged(service):
    api = client(service)
    assert api.get('/jobs').status_code == 401
    assert api.get('/jobs', headers=PROXY).status_code == 401, "the proxy's header isn't a token"
    assert api.get('/jobs', headers={'Authorization': 'Bearer secret-token'}).status_code == 200


def test_the_page_shows_status_queue_problems_and_libraries(service):
    api = client(service)
    api.put('/libraries', headers={'Authorization': 'Bearer secret-token'}, json={'enabled': ['lib-1']})
    service.poller.poll_once(now=NOW)
    queued = service.db.queue()
    assert queued
    failing = queued[-1]
    service.db.claim(now=NOW + 10**9)  # the first job, now running
    service.db.fail(dict(failing), 'ffmpeg exited with <status 1>', now=NOW, permanent=True)

    page = api.get('/ui', headers=PROXY)
    html = page.text
    assert '<h2>Status</h2>' in html and 'large-v3' in html and 'connected' in html
    assert 'Now transcribing' in html and '<h2>Queue (' in html
    assert '<h2>Problems</h2>' in html and 'ffmpeg exited with &lt;status 1&gt;' in html, 'errors are escaped'
    assert '<h2>Libraries</h2>' in html and 'Podcasts' in html and 'Jellyfin (asked for in Miru)' in html
    assert '>owner<' in html
    assert api.get('/ui/sections', headers=PROXY).text.startswith('<section id="status">')


def test_no_token_and_no_inline_code(service):
    api = client(service)
    for path in PATHS:
        response = api.get(path, headers=PROXY)
        assert 'secret-token' not in response.text, path
        assert SECRET not in response.text, path
        assert response.headers['cache-control'] == 'no-store'
        assert "script-src 'self'" in response.headers['content-security-policy']
        assert "frame-ancestors 'none'" in response.headers['content-security-policy']
    html = api.get('/ui', headers=PROXY).text
    assert '<script>' not in html and 'style=' not in html and ' on' + 'click' not in html


def test_titles_are_escaped(service):
    api = client(service)
    api.put('/libraries', headers={'Authorization': 'Bearer secret-token'}, json={'enabled': ['lib-1']})
    service.poller.poll_once(now=NOW)
    item, episode = service.db.queue()[0]['item_id'], service.db.queue()[0]['episode_id']
    service.db.execute('UPDATE job SET title = ? WHERE item_id = ? AND episode_id = ?', ('<img src=x>', item, episode))
    html = api.get('/ui', headers=PROXY).text
    assert '<img src=x>' not in html and '&lt;img src=x&gt;' in html


def test_only_the_pages_own_files(service):
    api = client(service)
    assert api.get('/ui/static/ui.js', headers=PROXY).headers['content-type'].startswith('text/javascript')
    assert api.get('/ui/static/ui.css', headers=PROXY).headers['content-type'].startswith('text/css')
    for name in ('../config.py', '..%2Fconfig.py', 'other.js', 'ui.py'):
        assert api.get(f'/ui/static/{name}', headers=PROXY).status_code == 404, name


def test_the_csrf_token_is_per_user_and_day():
    day = 20_000
    token = csrf_token(SECRET, 'owner', day)
    assert csrf_valid(SECRET, 'owner', token, now=day * 86400 + 10)
    assert csrf_valid(SECRET, 'owner', token, now=(day + 1) * 86400 + 10), 'a page left open overnight'
    assert not csrf_valid(SECRET, 'owner', token, now=(day + 2) * 86400)
    assert not csrf_valid(SECRET, 'someone', token, now=day * 86400)
    assert not csrf_valid('other-secret', 'owner', token, now=day * 86400)
    assert not csrf_valid(SECRET, 'owner', '', now=day * 86400)


def test_the_page_carries_its_token(service):
    html = client(service).get('/ui', headers=PROXY).text
    assert f'<meta name="csrf-token" content="{csrf_token(SECRET, "owner")}">' in html


def test_times_read_as_ago():
    assert ago(None) == 'never'
    assert ago(NOW - 30, now=NOW) == 'just now'
    assert ago(NOW - 300, now=NOW) == '5 min ago'
    assert ago(NOW - 7200, now=NOW) == '2 h ago'
    assert ago(NOW - 3 * 86400, now=NOW) == '3 d ago'
