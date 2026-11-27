from dataclasses import replace

from fastapi.testclient import TestClient

from conftest import NOW

from kaku.api import create_app
from kaku.db import BACKLOG, NEW
from kaku.db import NOW as ASKED
from kaku.ui import csrf_token

SECRET = 'ui-secret'
AUTH = {'Authorization': 'Bearer secret-token'}
# Podcasts (lib-1): item-1 with episode-1 (3 days old: new) and episode-2 (15 days: backlog).
NEW_EPISODE, OLD_EPISODE = ('item-1', 'episode-1'), ('item-1', 'episode-2')


def setup(service, poll=True):
    service.config = replace(service.config, ui_secret=SECRET)
    api = TestClient(create_app(service))
    api.put('/libraries', headers=AUTH, json={'enabled': ['lib-1', 'lib-2']})
    if poll:
        service.poller.poll_once(now=NOW)
    headers = {'X-Kaku-UI': SECRET, 'X-authentik-username': 'owner', 'Origin': 'http://testserver',
               'X-CSRF-Token': csrf_token(SECRET, 'owner')}
    return api, headers


def act(api, headers, action, **body):
    return api.post('/ui/api/action', headers=headers, json={'action': action, **body})


def queued(service):
    return {(job['item_id'], job['episode_id']): job['priority'] for job in service.db.queue()}


def test_a_poll_remembers_each_librarys_shows_and_books(service):
    setup(service)
    assert [(show['item_id'], show['title'], show['waiting']) for show in service.db.shows('lib-1')] == [('item-1', 'テストポッドキャスト', 2)]
    assert [show['title'] for show in service.db.shows('lib-2')] == ['テストの本']


def test_skip_keeps_a_show_out_but_an_ask_still_counts(service):
    api, headers = setup(service)
    assert act(api, headers, 'rule', libraryId='lib-1', itemId='item-1', value='skip').status_code == 200
    assert NEW_EPISODE not in queued(service) and OLD_EPISODE not in queued(service)
    service.poller.poll_once(now=NOW + 600)
    assert NEW_EPISODE not in queued(service), 'the poller leaves it alone'
    assert api.post('/jobs', headers=AUTH, json={'itemId': 'item-1', 'episodeId': 'episode-1'}).status_code == 202
    assert queued(service)[NEW_EPISODE] == ASKED, 'an app asking for it still queues it'


def test_pause_holds_a_shows_jobs_until_resumed(service):
    api, headers = setup(service)
    act(api, headers, 'rule', libraryId='lib-2', itemId='book-1', value='pause')
    act(api, headers, 'rule', libraryId='lib-1', itemId='item-1', value='pause')
    assert service.db.claim(now=NOW + 10**9) is None, 'everything waiting is paused'
    assert 'show paused' in api.get('/ui', headers=headers).text
    act(api, headers, 'next', itemId='item-1', episodeId='episode-2')
    assert (service.db.claim(now=NOW + 10**9)['episode_id']) == 'episode-2', 'one asked for runs anyway'
    act(api, headers, 'rule', libraryId='lib-1', itemId='item-1', value='normal')
    assert service.db.claim(now=NOW + 10**9)['episode_id'] == 'episode-1'


def test_high_and_low_move_a_show_between_new_and_backlog(service):
    api, headers = setup(service)
    assert queued(service)[OLD_EPISODE] == BACKLOG
    act(api, headers, 'rule', libraryId='lib-1', itemId='item-1', value='high')
    assert queued(service)[OLD_EPISODE] == NEW
    act(api, headers, 'rule', libraryId='lib-1', itemId='item-1', value='low')
    assert queued(service)[NEW_EPISODE] == BACKLOG and queued(service)[OLD_EPISODE] == BACKLOG
    # And new episodes found later follow the rule.
    service.db.execute("DELETE FROM job")
    service.poller.poll_once(now=NOW + 600)
    assert queued(service)[NEW_EPISODE] == BACKLOG


def test_new_only_drops_the_backlog_but_not_a_high_shows(service):
    api, headers = setup(service)
    assert act(api, headers, 'library-backlog', libraryId='lib-1', value='off').status_code == 200
    assert OLD_EPISODE not in queued(service) and NEW_EPISODE in queued(service)
    service.poller.poll_once(now=NOW + 600)
    assert OLD_EPISODE not in queued(service), 'the poller skips the backlog'
    assert 'on, new only' in api.get('/ui', headers=headers).text
    act(api, headers, 'rule', libraryId='lib-1', itemId='item-1', value='high')
    service.poller.poll_once(now=NOW + 1200)
    assert queued(service)[OLD_EPISODE] == NEW, "a high-priority show's backlog comes along"
    act(api, headers, 'rule', libraryId='lib-1', itemId='item-1', value='normal')
    service.db.execute("DELETE FROM job")
    act(api, headers, 'library-backlog', libraryId='lib-1', value='on')
    service.poller.poll_once(now=NOW + 1800)
    assert queued(service)[OLD_EPISODE] == BACKLOG, 'backlog on again'


def test_the_library_page(service):
    api, headers = setup(service)
    page = api.get('/ui/library?id=lib-1', headers=headers)
    assert page.status_code == 200 and 'Podcasts: shows' in page.text and 'テストポッドキャスト' in page.text
    assert 'data-view="library:lib-1"' in page.text and 'data-action="rule"' in page.text and 'data-value="skip"' in page.text
    assert 'Japanese Books: books' in api.get('/ui/library?id=lib-2', headers=headers).text
    assert api.get('/ui/library?id=lib-1').status_code == 403
    assert api.get('/ui/library?id=nope', headers=headers).status_code == 404
    assert 'href="/ui/library?id=lib-1"' in api.get('/ui', headers=headers).text
    # A change from the library page answers with that page's sections, and is recorded.
    answer = act(api, headers, 'rule', libraryId='lib-1', itemId='item-1', value='high', view='library:lib-1')
    assert answer.text.startswith('<section id="shows">') and 'high priority' in answer.text
    assert api.get('/ui/sections?view=library:lib-1', headers=headers).text.startswith('<section id="shows">')
    assert service.db.changes()[0]['detail'] == 'テストポッドキャスト: high'


def test_bad_rules_are_refused(service):
    api, headers = setup(service)
    assert act(api, headers, 'rule', libraryId='lib-1', itemId='item-1', value='sometimes').status_code == 400
    assert act(api, headers, 'rule', libraryId='lib-1', itemId='book-1', value='skip').status_code == 404, 'not in this library'
    assert act(api, headers, 'rule', libraryId='nope', itemId='item-1', value='skip').status_code == 404
    assert act(api, headers, 'library-backlog', libraryId='lib-1', value='maybe').status_code == 400
    assert service.db.rules('lib-1') == {}
