---
title: Support
description: How to report a bug, ask a question or suggest a feature, and what to include.
---

Amatsubame is a hobby project. Help happens through GitHub issues, as time allows: there's no
guaranteed support or response time.

## Reporting a bug

Open an issue at
[github.com/zacaronii/amatsubame/issues](https://github.com/zacaronii/amatsubame/issues). Search the
open issues first, in case someone has already reported it.

A good report includes:

- **The app**: Yomu, Miru, Kiku, Hiku or Kaku.
- **Its version**, from **Settings ▸ About** (the number in brackets is the build). In Hiku it's on the
  app's main screen. For Kaku, the version is in its `/health` answer.
- **Your device and system**, for example "iPad, iPadOS 26.1" or "Mac, macOS 26.0".
- **What you did**, step by step, **what you expected**, and **what happened instead**.
- **Your servers' versions**, if it's about Kavita, Jellyfin, Audiobookshelf or AnkiConnect.

### Attaching a log

Yomu, Miru and Kiku keep a small log of server errors, syncing, dictionary updates and setup. To send
it:

1. Open **Settings ▸ Advanced**.
2. Under **Troubleshooting**, tap **Export Logs** and save or share the file.
3. **Read it before you attach it.** Tokens, keys and passwords are blanked out, but the log can still
   show your servers' addresses and the names of things in your libraries. Remove anything you'd rather
   not post publicly.

GitHub issues are public, so the same goes for screenshots: crop or cover anything private, such as
server addresses or titles.

For Kaku, the output of `docker compose logs kaku` (checked the same way) usually shows what went wrong.

## Questions and feature requests

Questions and ideas are welcome as issues too. For a feature request, say what you'd like to do and
why, rather than only how; it helps to know what you're reading, watching or listening to when it
would help (no titles needed).

## Before you ask

- [Getting started](/getting-started/) covers building and the first launch.
- [Lookup and Anki](/lookup-and-anki/) covers dictionaries, word marks and cards.
- [Kaku](/kaku/) covers running the transcription server.
- The [Privacy](/privacy/) page lists what the apps contact and why.
