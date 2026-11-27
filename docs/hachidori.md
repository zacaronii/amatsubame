# Hachidori: research for linking the apps

Research for making Yomu, Miru, Kiku and Hiku work with a [Hachidori](https://github.com/bee-san/hachidori) host (GPL-3.0). The work is tracked in issues #29–#40: `Packages/HachidoriKit` implements sections 1–4; the Mac apps use it for lookups, and every app for counts, the popup's settings and dictionaries (Settings ▸ Connections ▸ Hachidori). Sources were read at these versions:

| Name here | Project | Version |
| --- | --- | --- |
| Hachidori | bee-san/hachidori | main 7075d5c (= 0.5.2 for everything below) |
| Hachidori 0.3.2 | the same, as pinned by hachidori-docker | 5f986e47 (0.3.2 + 5) |
| relay | bee-san/hachidori-anki | v0.0.5 (deployed), v0.0.6 |
| hachidori-docker | ksyasuda/hachidori-docker | b89564d |
| hoshidicts (ours) | Manhhao/hoshidicts, vendored until 2026-11-15; now bee-san's fork (Vendor/hoshidicts/VENDORED.md) | e6af33e1 |
| hoshidicts (Hachidori's) | bee-san/hoshidicts fork | 20019e4b (0.3.2), 088ac5de (latest) |

The test host is hachidori-docker on a home server, reached over the LAN or Tailscale only (it has no authentication or TLS). Its address is a contributor-specific detail and isn't recorded here.

## 1. The Sharing wire protocol

### Transport

- The relay is a plain `ws://` server on port 8771. Paths: `/host` (the hosting browser, loopback only) and `/link` (linked clients).
- Origins it accepts (`addon/server.py`, `refusal()`): `chrome-extension://…` (v0.0.6 also `moz-extension://…`), or, on `/link` only, exactly **`hoshi://hoshidicts`** for native clients. Anything else gets 403. hachidori-anki PR #5's description says `hoshidicts://client`, but the merged code (in v0.0.4 and later) checks `hoshi://hoshidicts`; a live probe of the deployed v0.0.5 relay confirmed it (`hoshidicts://client` is refused, `hoshi://hoshidicts` gets the host's hello).
- `/link` answers 503 while no host is connected: retry.
- The relay forwards text frames opaquely and pings every 20 s with `{"kind":"ping"}`. There's no idle timeout.
- A native client is treated exactly like a linked browser by the host: same request allowlist, no per-origin rules.

### Frames

Client → host (`extension/sharing-protocol.js` `parseClientFrame`):

```json
{"kind":"hello","protocol":1,"version":"0.3.0","name":"Yomu","capabilities":[]}
{"kind":"request","id":7,"message":{"target":"hoshidicts-offscreen","type":"hd_lookup","requestId":7,"text":"食べたかった","maxResults":32,"scanLength":16}}
{"kind":"pong"}
```

`protocol` must be 1 (otherwise `bye` and close). `capabilities` is up to 32 strings; browsers send `["linked-anki-v1","linked-anki-v2"]`, native clients `[]`.

Host → client (`parseHostFrame`): `hello`, `reply`, `storage`, `word-status`, `ping`, `bye`. Clients must **ignore unknown kinds** (Mangatan's draft throws on them and would reconnect each time the host sends `word-status`).

- `hello`: `{kind, protocol, version, name, dictionaryCount, capabilities, snapshot}`. `snapshot` holds the six shared keys: `dictionaryState`, `options`, `customDictionarySource`, `dictionaryUpdates`, `lookupStats` (the descriptor only) and `wordStatusOverrides`. Lookup-count rows aren't in it.
- `reply`: `{kind:"reply", id, response}`, with `response` = `{type:"<type>_result", requestId, ok, error, errorCode?, …payload}`; engine replies also carry an integer `generation`.
- `storage`: `{kind:"storage", changes:{"<key>": value | null}}`, one per committed batch, broadcast to every client including the writer. `null` removes the key.
- `word-status`: `{kind:"word-status", revision}`: the host's Anki index changed, so re-ask `hd_anki_word_status`.

### Capabilities

| Capability | Means |
| --- | --- |
| `hoshidicts-api-v1` | The host answers `hd_api_*` (the Yomitan HTTP API on port 19633) |
| `linked-anki-v1`, `linked-anki-v2` | Host-owned Anki mining; v2 is Template-aware and is required (in the *client's* hello) to write `options.anki` |
| `linked-import-v1` | Chunked dictionary uploads (`hd_import_begin/chunk/commit/abort`) |
| `language-profiles-v1` | The host has several languages; clients opt in with `hd_language_profiles_opt_in` (0.4+). Without opting in a client gets the Japanese view, which is all we need |
| `mcp-configuration-v1` | The host serves `hachidori-mcp` requests (0.5+) |

The deployed hachidori-docker advertises `hoshidicts-api-v1`, `linked-anki-v1`, `linked-anki-v2`, `linked-import-v1`.

### Requests

Clients never send `storage` frames: every change is a request, which the host commits and broadcasts. The ones that matter to us (target, then type):

| Target | Request | Notes |
| --- | --- | --- |
| `hoshidicts-offscreen` | `hd_lookup` `{text, maxResults?, scanLength?, options?}` | `{results, dictionaryCount, generation}` (section 3) |
| | `hd_kanji` `{character}`, `hd_lookup_dictionary`, `hd_segment`, `hd_styles`, `hd_status` | reads |
| | `hd_media` `{generation, dictionary, path}` | `{dataUrl}`; fails if `generation` isn't current |
| | `hd_custom_append` `{entry:{term, reading, definition}}` | adds a personal dictionary entry |
| `hoshidicts-worker` | `hd_state_read`, `hd_custom_read`, `hd_lookup_stats_read` | reads |
| | `hd_lookup_stats_record` `{term, reading}` | +1, host clock (section 4) |
| | `hd_word_status_override` `{headword, status:"known"\|"ignored"\|null}` | `{revision}` |
| | `hd_options_write` `{baseRevision, options}` | CAS: a stale base gets `conflict:true` and the current options |
| | `hd_state_cas`, `hd_custom_cas`, `hd_known_words_add` | CAS writes; see below for what hachidori-docker routes |
| `hachidori-anki` | `hd_anki_status/view/preflight/submit/browse/maturity/word_status` | host-owned mining (section 6) |

hachidori-docker b89564d routes `hd_lookup`, `hd_lookup_dictionary`, `hd_segment`, `hd_kanji`, `hd_media`, `hd_styles`, `hd_status`, `hd_custom_append`, `hd_custom_save`, `hd_state_read`, `hd_custom_read`, `hd_options_write`, `hd_state_cas` (presentation fields only), `hd_lookup_stats_read/record`, `hd_word_status_override` and the Anki, update and linked-import requests. It does **not** route `hd_custom_cas`, `hd_known_words_add` or language profiles.

### Records

**Lookup counts.** A descriptor under `lookupStats`: `{generation:"<uuid>"|null, revision}` (the UUID names the current count set; a reset starts a new one). Rows under

```
lookupStats:"<generation uuid>":["<term>","<reading>"]
```

hold `{term, reading, lookupCount, firstLookedUpAt, lastLookedUpAt}` (epoch ms). `term` and `reading` are the **dictionary headword of the first result**, trimmed and NFC-normalised, not the text that was tapped.

**Known and ignored words.** `wordStatusOverrides`: `{revision, known:[headword…], ignored:[headword…]}`; each headword is in at most one list.

**Personal dictionary.** `customDictionarySource`: `{schemaVersion:1, revision, semanticRevision:"<sha256 hex>", text}`, where `text` has one `term, reading, definition` entry per line (`#` comments, `\` escapes). The host compiles it into a dictionary titled "Hachidori Custom Dictionary".

**Settings.** `options` is one revisioned object. The keys a lookup client needs: `maxResults` (32), `scanLength` (16), `frequencyDictionary`, `frequencyOrder`, `showLookupCounts` (true), `showCompactDefinitionSummary` (false), `compactDefinitionSummaryCount` (3), `compactDefinitionSummaryDictionary`, `kanjiClickDictionary`, `pitchAccentFuriganaDictionary`, and `anki`. **`options.anki` includes the AnkiConnect URL and API key, and the host sends it to every linked client as stored.**

**Dictionaries.** `dictionaryState`: `{schemaVersion:1, revision, dictionaries:[{id, title, displayName, enabled, favorite, revision, frequencyMode, termCount, frequencyCount, pitchCount, kanjiCount, mediaCount, longKeyLength, isUpdatable, indexUrl, downloadUrl, …}], groups}`. Order is array order.

### Reconnect and offline

- Browsers reconnect with `min(10 s, 500 ms·2^n)` backoff and take the new hello's snapshot as one batch.
- A linked browser mirrors the shared keys locally, so the popup and Settings still show the last state, but **lookups fail while the host is unreachable** and edits aren't queued: a request waits up to 5 s for a connection, then fails. A write that was already sent when the link dropped is reported as "outcome unknown" and never retried.

## 2. Native clients today

- **Mangatan** (1Selxo/Mangatan PR #106, draft, Flutter with local hoshidicts) is the closest model: `ws://` + `Origin: hoshi://hoshidicts`, hello with empty capabilities, backoff 0.5–10 s, 5 s connect and 15 s request timeouts. It sends only reads (`hd_lookup`, `hd_lookup_dictionary`, `hd_kanji`, `hd_styles`, `hd_media`, `hd_status`) and maps the host's results onto its own local result types, drawn by its own popup. It takes `frequencyDictionary`, `frequencyOrder` and `primaryReading` from `snapshot.options`. No counts, known words or Anki. While linked it has no local fallback.
- **Hoshi Reader Desktop** (Manhhao/Hoshi-Reader-Desktop PR #11, draft, Tauri): the same Origin and hello, lazy reconnect, and copies dictionaries with the relay's `GET /dictionaries/<id>`.
- **SubMiner** (ksyasuda/SubMiner PR #266, merged) isn't native: it embeds the Hachidori extension in Electron, so the relay sees a `chrome-extension://` origin. Mining stays on SubMiner's own AnkiConnect.
- **Kimochi** bridges an embedded extension to `/link` with `Origin: hoshi://hoshidicts`; **GameSentenceMiner** embeds the extension.

## 3. Lookups while linked

`hd_lookup` returns hoshidicts' own result structure, the same data our C API gives:

- result: `matched`, `deinflected`, `trace:[{name, description}]`, `preprocessorSteps`, `term`
- term: `expression`, `reading`, `rules`, `score` (a double in Hachidori's engine; int32 in ours), `furigana`, `glossaries:[{dictionary, glossary:<Yomitan glossary JSON as a string>, definitionTags, termTags, tags}]`, `frequencies:[{dictionary, frequencies:[{value, displayValue}]}]`, `pitches:[{dictionary, pitches:[{position, pattern, nasal, devoice}], transcriptions}]`

So our popup can draw host results with its own renderer: `EntryRenderer` and `StructuredContentRenderer` already turn this structure into the popup's HTML. Dictionary images come from `hd_media` as data URLs (keep the reply's `generation` for it), and dictionary CSS from `hd_styles`. The HTTP API's `/termEntries` is Yomitan-shaped instead and costs a new request each time, so `/link` is the better path.

Measured from a Mac to the home server (hachidori-docker with the five default dictionaries):

| Path | `hd_lookup` over an open `/link` | `/termEntries` (new HTTP request each) |
| --- | --- | --- |
| Tailscale (at home) | 21–33 ms | 26–86 ms |
| LAN (Wi-Fi) | 29–76 ms | 70–165 ms |

Replies are 17–34 KB for 3–5 results. Tailscale from outside the home wasn't measured; expect a cellular round trip on top. A local lookup in our engine takes a few milliseconds, so linked lookups are noticeably slower but fine for taps.

## 4. Lookup counts

- **When:** each new lookup that shows results, counted once per popup visit: tabs, Back and refreshes reuse the visit; tapping a link or another word starts a new one. Misses don't count, and there is no time window (looking the same word up later counts again). Kanji entries don't count.
- **What:** the first result's headword (`results[0].term.expression` and `reading`).
- **How a linked client reports it:** `hd_lookup_stats_record {term, reading}` to `hoshidicts-worker`. The host adds 1 with its own `Date.now()`, writes the descriptor and the row in one batch and broadcasts them. `hd_lookup_stats_read` reads a row.
- **Offline:** there is **no batch, count or timestamp form**, and lost increments are never retried. The only writer of timestamped rows is backup restore, which clients can't send. Reporting an iPhone's offline lookups faithfully needs a new request upstream, for example `hd_lookup_stats_merge {rows:[{term, reading, count, firstLookedUpAt, lastLookedUpAt}]}`. Until then, the closest we can do is send `hd_lookup_stats_record` once per queued lookup on reconnect, which gets the counts right but stamps them with the sync time.

## 5. "First meaning" and the count chip

Hachidori's compact definition summary (`render/popup.js` `extractCompactDefinitionSummary`, `updateCompactSummary`):

- Shown next to **each** result's headword when `showCompactDefinitionSummary` is on (off by default).
- Dictionary: `compactDefinitionSummaryDictionary` first if set, then the result's dictionaries in order; the first dictionary that yields anything wins.
- Items, in order of preference: Jitendex's `data-content="glossary"` lists; Sanseido-style 語義/語釈 senses; the first `ul`/`ol`; otherwise the top-level senses. Parts of speech, redirects, sources, attribution, examples, forms, `rt`/`rp` and images are skipped; text is split on `•`.
- Up to `compactDefinitionSummaryCount` unique items (3 by default, 1–6), 240 characters at most (cut with "…"), joined with " · ".

The count chip ("Looked up N time(s)") appears only on the **first** result, after its frequencies, when `showLookupCounts` is on. Hachidori has no "First lookup" wording; `firstLookedUpAt` is stored but not shown.

## 6. Anki

| | Our AnkiConnect path (today) | Mining through the host (`linked-anki-v2`) |
| --- | --- | --- |
| Note type and fields | Our Lapis preset, field names from `modelFieldNames` | The host's Templates (`{expression}`, `{glossary}`… markers), rendered by the host |
| Media | Anything via `storeMediaFile`: picture, sentence audio, word audio | A JPEG screenshot (≤ 6 MiB) and text-to-speech WAV only; word audio from the host's URL sources. **No sentence audio** |
| Duplicates | `addNote` with `duplicateScope: "deck"` | The Template's scope (note type on the test host); the host's index covers the first Template only |
| Word marks | Our `findNotes` queries (`is:review -is:learn prop:ivl>=21` like Hachidori's, `-is:new`) | `hd_anki_word_status` (known/learning/unknown) plus `wordStatusOverrides`, per request online |
| Offline | Outbox: the card is rendered at mine time and sent later | Impossible: a submission needs the host's live lookup result, engine `generation` and a per-process `configKey`, all invalid after a restart or dictionary change |
| Auth | AnkiConnect API key | The relay has none |

The host's headless AnkiConnect already accepts exactly what our apps send (media through `storeMediaFile` with `data`, deck-scoped duplicates, `findNotes`). **Recommendation: keep our AnkiConnect path and Outbox.** Linked mining can't carry Miru's and Kiku's sentence audio, and it can't queue. Two optional borrowings: take the deck, note type and field markers from the host's Template (`GET /ankiCardFormats`, or `options.anki.templates` in the snapshot) so the apps and Hachidori make the same cards; and count the host's known/ignored words in our word marks.

## 7. Dictionary exports

- `GET /dictionaries` lists `{id, title, revision, size, fileName}`; `GET /dictionaries/<id>` streams a one-dictionary **Hachidori backup archive**: a stored (uncompressed) ZIP64 with `hachidori-backup.json` and the dictionary's **compiled hoshidicts folder** (`dictionaries/0/`), not a Yomitan zip. Both are on the **Yomitan API port (19633)**, not the relay's 8771; hachidori-docker serves them there itself (its list reply is the engine's, `{type, ok, dictionaries}`), and an unknown id is a 404.
- `hachidori-backup.json` carries the host's whole `options`, **AnkiConnect URL and key included**. `HostDictionaryExports.unpack` extracts only the dictionary folder and never reads it; the folder's own `index.json` has the title, revision and links, and the kinds come from `dictionaryState` (`index.json` counts frequencies and pitches together as `termMeta`).
- Sending one the other way is `linked-import-v1` (Hachidori's `extension/linked-import.js`): target `hachidori-linked-import`, `hd_import_begin {fileName, size, replace}` → `{token, chunkBytes}` (1 MiB), `hd_import_chunk {token, offset, data: base64}` strictly in order, `hd_import_commit {token}` (the host's import reply) or `hd_import_abort`. Yomitan zips only (MDX is refused), at most 512 MiB in hachidori-docker, whose commit waits for an import or update already running. `HachidoriLink.sendDictionary` implements it (#36).
- **Our engine now loads those folders.** Hachidori uses bee-san's hoshidicts fork, which writes format markers `.hoshidicts_5`/`_6` (term scores stored as doubles, an extra `scan.idx`). Upstream hoshidicts has since written its own, different `_5` (a perfect-hash table), so the two `_5`s must never be mixed. Since 2026-11-15 the apps vendor bee's fork at the commit the latest Hachidori release pins (a newer engine reads every older format, including the `_3`/`_4` folders our earlier engine wrote); `DictionaryFormat` flags a folder from a newer engine instead of skipping it silently.
- Size: the archives are about the compiled size: Jitendex 99 MB, JMnedict 76 MB, Jiten frequency 72 MB, Bee's Kanji 61 MB, Bee's Grammar 35 MB (about 336 MB for Hachidori's five defaults). The Yomitan zips are 2–5 times smaller, and importing one takes well under a second on a Mac.
- Two ways to give an iPhone the host's dictionaries:
  1. **Re-import the same Yomitan zips** from each dictionary's `downloadUrl` in `dictionaryState`, at the revision the host has. Our engine is unchanged and downloads are small; the host's personal dictionary is rebuilt locally from `customDictionarySource.text`.
  2. **Load the host's compiled folders**, which means vendoring bee-san's fork instead of upstream (the C API change is small: `score` becomes a double). Downloads are 2–5 times bigger, and we'd track a fork.
- To look up "like the host" locally we also need its order, enabled flags, display names and the per-feature dictionary choices (`frequencyDictionary`, `frequencyOrder`, `kanjiClickDictionary`…), mapped by `id`/`title`. We keep only order, enabled and the frequency sort dictionary today.

## 8. What doesn't fit on iOS, and what we'd do instead

- **No background socket.** iOS suspends apps in the background, so `/link` is open only while an app is in front. The apps connect on launch and when they come forward (`HachidoriLink.reconnectNow` cuts the backoff short), and sync then; there's no live link in the background.
- **Offline.** A linked browser just fails offline. An iPhone app is offline often, so it looks up locally with its copy of the host's dictionaries and queues its changes. That's our own behaviour, not the spec's:
  - **Counts** (every platform, the Mac included): each counted lookup also goes into the app's outbox (`hachidoriLookupCount`, one job per headword holding a count). The handler sends `hd_lookup_stats_record` once per lookup and takes each one off the job as it goes; an `outcomeUnknown` isn't resent, as in Hachidori. While linked, the popup shows `hd_lookup_stats_read` plus what's still queued, and the local row takes that number, so the count shown offline continues from the host's.
  - **Known and ignored words** (#86): `WordStatusStore` keeps the list in the setup's database, so every app has it with or without a host; `WordMarks` never marks those words. With Hachidori on, a change is kept with `pendingHost` (a cleared word as a row without a status) and queued as `hachidoriWordStatus` (one job per word, carrying only the word); the handler sends the word's current mark with `hd_word_status_override`, which changes only that headword, so apps and browsers never conflict. On each link, any app queues every waiting word (Hiku's extension doesn't link, so its marks go with the next app), and the host's `wordStatusOverrides` replace ours except for words still waiting. Turning Hachidori on marks every local word waiting, so they join the host's list; turning it off drops the waiting flags.
  - **Settings:** the host's popup options are saved as ours whenever they come in, so the popup looks the same offline; Settings ▸ Popup stays read-only while Hachidori is on.
- **Local Network.** Reaching a LAN address prompts for Local Network access (our apps already declare it); a Tailscale address doesn't. Plain `ws://` is allowed by our existing ATS settings.
- **Finding the host.** The relay doesn't advertise itself (no Bonjour), so "find it" can only try a remembered address; otherwise the address is typed, as in Hachidori's own Sharing page.
- **The API key in `options.anki`.** Every linked client receives the host's AnkiConnect key. Our apps keep their own Anki settings and shouldn't copy it.
