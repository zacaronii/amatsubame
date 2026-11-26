# Contributing

Bugs and ideas are GitHub issues (the issue forms ask for the app, version and device). Work goes issue →
branch → pull request → `dev`, and `dev` goes to `main` when it has been tried and is ready to ship.
[CLAUDE.md](../CLAUDE.md) has the conventions: titles, labels, tests.

## Branches

- **`dev`** is where work lands. Each fix or feature is a branch from `dev` and a pull request back
  into it, merged once the builds and tests pass. Dev TestFlight builds (iPhone, iPad and Mac) come
  from `dev`, so testing always covers everything merged so far.
- **`main`** only gets what has been tried. One pull request, `dev` → `main` (labelled `chore`), is
  merged when the next release is ready; releases come from `main`. It stays the default branch, so
  `Fixes #N` closes an issue when its fix reaches `main`. Until then the issue carries `in dev`.
- **Something wrong after a merge** gets a new pull request into `dev`, not a reopened one. If the
  problem was in something not yet released, label it `follow-up`: release notes leave it out, since
  users only ever see the fixed version. A change that breaks `dev` badly can be reverted (GitHub's
  Revert button on the pull request) and redone.
- **An urgent fix for a release** is a branch from `main` and a pull request into it; `main` is then
  merged into `dev`.
