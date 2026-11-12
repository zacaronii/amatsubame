from dataclasses import replace

from conftest import NOW

from kaku import model_key
from kaku.db import BACKLOG, NEW, NOW as NOW_PRIORITY

KEY = model_key('large-v3')


def enable_podcasts(service):
    service.db.sync_libraries(service.audiobookshelf.libraries())
    service.db.set_enabled('lib-1', True)


def test_only_enabled_libraries_are_polled(service):
    assert service.poller.poll_once(now=NOW) == 0
    assert not any('/items' in path for path in service.audiobookshelf.requests), 'nothing polled before a library is on'
    enable_podcasts(service)
    assert service.poller.poll_once(now=NOW) == 2
    assert not any('lib-0' in path or 'lib-2' in path for path in service.audiobookshelf.requests)
    service.db.set_enabled('lib-2', True)
    assert service.poller.poll_once(now=NOW) == 1
    assert ('book-1', '') in {(job['item_id'], job['episode_id']) for job in service.db.queue()}
    assert not any('lib-0' in path for path in service.audiobookshelf.requests), 'the English library stays off'


def test_new_episodes_come_before_the_backlog(service):
    enable_podcasts(service)
    service.poller.poll_once(now=NOW)
    queue = service.db.queue()
    assert [(job['episode_id'], job['priority']) for job in queue] == [('episode-1', NEW), ('episode-2', BACKLOG)]


def test_polling_again_queues_nothing_twice(service):
    enable_podcasts(service)
    assert service.poller.poll_once(now=NOW) == 2
    assert service.poller.poll_once(now=NOW + 300) == 0
    # The podcast didn't change (same updatedAt), so its episodes weren't fetched again.
    assert service.audiobookshelf.requests.count('/api/items/item-1?expanded=1') == 1


def test_asking_now_jumps_the_queue(service):
    enable_podcasts(service)
    service.poller.poll_once(now=NOW)
    episode = service.audiobookshelf.episode('item-1', 'episode-2')
    assert service.db.offer(episode, NOW_PRIORITY, KEY, now=NOW + 1)
    assert service.db.queue()[0]['episode_id'] == 'episode-2'
    assert service.db.claim(now=NOW + 2)['episode_id'] == 'episode-2'


def test_a_changed_file_or_model_is_transcribed_again(service):
    enable_podcasts(service)
    service.poller.poll_once(now=NOW)
    while service.worker.run_once():
        pass
    assert service.db.counts() == {'done': 2}
    episode = service.audiobookshelf.episode('item-1', 'episode-1')
    assert not service.db.offer(episode, BACKLOG, KEY, now=NOW)
    grown = replace(episode.tracks[0], size=episode.tracks[0].size + 1)
    assert service.db.offer(replace(episode, tracks=(grown,)), BACKLOG, KEY, now=NOW)
    assert service.db.offer(service.audiobookshelf.episode('item-1', 'episode-2'), BACKLOG, 'large-v4/p2', now=NOW)
    assert len(service.db.queue()) == 2


def test_failures_are_retried_then_kept(service):
    enable_podcasts(service)
    service.poller.poll_once(now=NOW)
    job = service.db.claim(now=NOW)
    service.db.fail(job, 'network', now=NOW)
    assert service.db.job('item-1', job['episode_id'])['state'] == 'queued'
    assert service.db.claim(now=NOW + 1)['episode_id'] != job['episode_id'], 'waits before retrying'
    for attempt in range(2):
        again = service.db.claim(now=NOW + 100_000)
        service.db.fail(again, 'network', now=NOW)
    assert service.db.job('item-1', job['episode_id'])['state'] == 'failed'
    # Polling doesn't bring it back; asking for it does.
    episode = service.audiobookshelf.episode('item-1', job['episode_id'])
    assert not service.db.offer(episode, BACKLOG, KEY)
    assert service.db.offer(episode, NOW_PRIORITY, KEY)


def test_switching_a_library_off_drops_its_waiting_jobs(service):
    enable_podcasts(service)
    service.poller.poll_once(now=NOW)
    service.db.set_enabled('lib-1', False)
    assert service.db.queue() == []


def test_worker_writes_json_and_vtt(service):
    import json
    import os
    enable_podcasts(service)
    service.poller.poll_once(now=NOW)
    assert service.worker.run_once()
    saved = service.db.transcript('item-1', 'episode-1')
    transcript = json.load(open(saved['path'], encoding='utf-8'))
    assert transcript['item'] == {'libraryItemId': 'item-1', 'episodeId': 'episode-1', 'libraryId': 'lib-1'}
    assert transcript['source']['model'] == 'large-v3' and transcript['source']['fingerprint'] == '200:35300896:2179.3'
    assert [s['text'] for s in transcript['sentences']] == ['今日は晴れ。', '明日も？']
    vtt = open(saved['path'][:-4] + 'vtt', encoding='utf-8').read()
    assert vtt.startswith('WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n今日は晴れ。')
    assert not os.listdir(os.path.join(service.config.data_dir, 'tmp')), 'audio deleted'


def test_a_book_is_one_transcript_on_audiobookshelfs_timeline(service):
    import json
    service.db.sync_libraries(service.audiobookshelf.libraries())
    service.db.set_enabled('lib-2', True)
    service.poller.poll_once(now=NOW)
    book = service.audiobookshelf.episode('book-1', '')
    assert book.is_book and [track.ino for track in book.tracks] == ['310', '311'], 'in track order'
    assert book.duration == 5400.5 and book.fingerprint == '310:43204000:2700.2+311:43204001:2700.2'
    assert book.track_at(2800) == (book.tracks[1], 2800 - 2700.25)
    assert service.worker.run_once()
    assert service.audiobookshelf.downloads == ['310', '311']
    saved = service.db.transcript('book-1', '')
    assert saved['path'].endswith('/book-1/book.json')
    transcript = json.load(open(saved['path'], encoding='utf-8'))
    assert transcript['item']['episodeId'] == '' and transcript['source']['duration'] == 5400.5


def test_running_jobs_are_requeued_after_a_restart(service):
    from kaku.db import Database
    enable_podcasts(service)
    service.poller.poll_once(now=NOW)
    service.db.claim(now=NOW)
    reopened = Database(service.config.data_dir + '/kaku.db')
    assert {job['state'] for job in reopened.queue()} == {'queued'}


def test_the_model_unloads_when_idle(service):
    enable_podcasts(service)
    service.poller.poll_once(now=NOW)
    service.worker.run_once()
    assert service.transcriber.loaded
    service.worker.idle_unload_seconds = 0
    import threading
    stop = threading.Event()
    service.db.set_enabled('lib-1', False)
    thread = threading.Thread(target=service.worker.run, args=(stop,))
    thread.start()
    service.worker.wake.set()
    stop.set()
    service.worker.wake.set()
    thread.join(5)
    assert not service.transcriber.loaded
