# Releasing

The four apps share one version (`MARKETING_VERSION` in `project.yml`), 0.x while in beta: the middle
number goes up for features, the last one for fix-only releases. They also share one build number,
the upload time, which only goes up.

- `scripts/upload-dev.sh` builds the current commit (normally `dev`) and tags it `build-<number>`.
  The iPhone and iPad apps go to the TestFlight **Dev** group. The Mac apps don't go to TestFlight:
  they're exported with Developer ID, notarized and stapled, uploaded as `<App>-<version>-<build>.zip`
  to the rolling `dev` release of
  [zacaronii/homebrew-amatsubame](https://github.com/zacaronii/homebrew-amatsubame) (each Dev build
  replaces the last), and the `@dev` casks (`yomu@dev`, `miru@dev`, `kiku@dev`, `hiku@dev`) point at
  them. The script writes the `@dev` casks from the release casks, and each pair conflicts, since
  they're the same app (`scripts/homebrew-casks.sh`; `scripts/tests/homebrew-casks-test.sh` tests
  it offline). Both scripts check every cask with `ruby -c` and `brew style` before pushing the tap,
  since one broken cask stops every brew command that reads it. A release doesn't rebuild: it promotes a Dev build that has been in use, once
  `dev` has been merged into `main`.
- `scripts/upload-dev.sh --ios-only` sends only the iPhone and iPad apps to TestFlight and leaves the
  tap alone, so the `@dev` casks stay on the last full build (for a backup or test build).
- **Pinned backups.** `miru@mpv` is Miru's last mpv-only build (`docs/AETHER_PLAN.md`), kept while the
  player moves to AetherEngine. Its zip is on its own release in the tap (`mpv-final-<date>`, which no
  script touches), and its cask is written by hand, with a fixed version and sha and `livecheck skip`.
  `homebrew-casks.sh` adds `<app>@mpv` to the release and `@dev` casks' conflicts whenever the tap has
  one. It isn't in the app repo's releases, so it never becomes "latest" and doesn't publish Kaku.
- `scripts/release.sh <build number>` checks that build's commit, tags it `v<version>`, creates the
  GitHub pre-release with generated notes, and opens the pull request that moves `dev` to the next
  fix version (0.2.0 out → 0.2.1), so every Dev build already carries the version it would ship as.
  The build is then added to the main tester group in App Store Connect.
- The same run makes the Mac apps for Homebrew: the Dev build's notarized Mac apps (or, if they're no
  longer on that Mac, the build's commit archived and signed the same way, `scripts/mac-developer-id.sh`),
  attached to the GitHub release as `<App>-<version>.zip`, and the release casks in
  [zacaronii/homebrew-amatsubame](https://github.com/zacaronii/homebrew-amatsubame) moved to them.
  `scripts/release.sh --mac-only <build number>` redoes just that part for a released build.
- Publishing the release also publishes Kaku's Docker image, tagged with the version
  (`ghcr.io/zacaronii/amatsubame-kaku:<version>`, `.github/workflows/kaku-image.yml`). Only `v<version>`
  releases do: any other release in the app repo skips it, so it can't move `latest`.
- The first feature (a PR labelled `idea` or `enhancement`) merged after a release also moves `dev`
  to the next feature version (0.2.1 → 0.3.0). If that's forgotten, the release script stops and
  says so.

When:

- About every two weeks: ship what has merged into `dev` if it passes the checklist; skip the cycle if
  nothing worthwhile merged.
- A merged bug fix shouldn't wait more than about a week: do a fix-only release if needed.
- iCloud (Stats and settings across devices) works in the Developer ID copies too: their provisioning
  profile carries the App Group and the iCloud Documents container, and they use the same app data as
  the TestFlight Mac apps did.
- TestFlight builds expire after 90 days, so never go more than about two months between releases.
- Bigger features use a GitHub milestone (for example "v0.4.0") and ship once its issues are closed.

The checklist (the script checks the first, second, fourth and fifth, and asks about the third and sixth;
the last is a script of its own):

- All four apps build for iOS and macOS.
- The tests pass: the packages, the apps' unit tests and Kaku's.
- Every pull request since the last release was checked by hand.
- No open issue has the "blocks release" label.
- The version fits: the middle number for a release with features, the last for fixes only.
- The build has been in use in the Dev group for a day or two.
- Every app and extension has a privacy manifest: `scripts/check-privacy-manifests.sh
  build.noindex/testflight/<build number>/*.xcarchive` lists each bundle and fails on one without.
