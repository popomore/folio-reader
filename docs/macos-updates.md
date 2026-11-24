# macOS releases and updates

Folio checks the signed Sparkle appcast in [GitHub Releases](https://github.com/popomore/folio-reader/releases). Stable builds can check automatically at startup and every 24 hours while running. Use **Settings → Updates** or **Check for Updates…** in the Folio menu to check manually.

Folio verifies the download before handing it to Sparkle. Workspaces and preferences live outside the app bundle. Open documents and native media playback can delay a restart.

## Verify locally

Run `scripts/prepare-update-qa` and use the directory printed on the last line. Serve its `server` subdirectory on loopback with `python3 -m http.server 18736 --bind 127.0.0.1 --directory "$qa/server"`. Open `"$qa/installed/Folio Update QA.app"` and its `Fixture.md`. Check for, download, and install the update from Settings. The local builds use a separate bundle identity and a temporary Sparkle key.

## Release notes

Write commit subjects and release notes in English. Automatic stable releases
generate their notes from conventional commits, using the same semantic-release
packages as MusicX. `fix:` increments the patch, `feat:` increments the minor,
and `!` or a `BREAKING CHANGE:` footer increments the major. Documentation and
maintenance commits alone do not release. Without an existing stable tag, the
first version is `1.0.0`. The app version comes from the release plan and tag;
Cargo package versions are independent.

The generated notes supply both the GitHub Release description and the signed
Sparkle appcast. Previews continue to use `.release/preview-notes.txt`. Manual
stable tag releases use `.release/notes.txt`.

## Automatic stable releases

Folio follows MusicX's branch policy: `main` publishes previews and `release`
publishes stable builds. To enable stable automation, a maintainer must first
create `release` from a tested `main` commit and allow the `release` branch in
the `folio-macos-release` environment. This change does not create that branch
or alter environment protection rules. Keep the existing signing settings below
and enable immutable GitHub releases. No personal access token is needed.

After reviewed changes reach `main` and pass Folio CI, fast-forward `release`
to the selected `main` commit. Do not add release-only commits: the source must
remain reachable from `origin/main`. Folio CI tests the release branch, including
the release automation tests. Its completed successful push run queues the
stable workflow on that exact branch. PR runs, forks, failed runs, other
workflows, and stale branch tips cannot start a new release.

The stable workflow saves the semantic version, English notes, source SHA, and
CI run ID as a release plan. If no release is needed, it skips signing and
publication. Otherwise it signs and notarizes the app and DMG, signs the Sparkle
update, and records the package hashes against the original plan. Only after
those packages have been retained does it create `vX.Y.Z`, stage the release,
verify the public downloads, and update Latest. Existing preview tag formats,
bundle identities, and update channels remain compatible.

Re-run the original stable workflow after an interruption. It retains its plan
and signed packages for 90 days and verifies their provenance and hashes on
retry. An existing tag must still point to the planned source; publication can
resume with the original bytes, including after a newer push. Missing or expired
artifacts and conflicting tags require recovery; the workflow never moves a tag
or rebuilds a published version. For a manual retry entry point, dispatch
`release-stable.yml` on `release` with the successful Folio CI `ci-run-id`.
Use the original run when its tag or signed packages already exist.

## Manual stable tag releases

1. Use a clean checkout of `origin/main` with passing Folio CI. Update `.release/notes.txt` for the release.
2. Create a new `vX.Y.Z` tag on that commit and push it when publication is authorized. The workflow uses the tag as the release version.
3. Verify the GitHub release, Apple Silicon DMG, Sparkle ZIP, and signed public appcast. The stable release becomes Latest.

A manual run of `release-macos.yml` checks a tag and builds a local update
fixture. An explicitly authorized tag push to the public repository publishes.
This remains available for existing tag-based releases; use automatic stable
releases for normal promotion. Both workflows use the repository workflow token.

Configure the following in the `folio-macos-release` environment:

| Setting | Purpose |
| --- | --- |
| `FOLIO_UPDATE_PUBLIC_KEY` variable | Stable Sparkle Ed25519 public key |
| `FOLIO_UPDATE_PRIVATE_KEY` secret | Corresponding signing seed |
| `FOLIO_APPLE_CERTIFICATE`, `FOLIO_APPLE_CERTIFICATE_PASSWORD` | Base64 Developer ID Application PKCS#12 certificate and password |
| `FOLIO_APPLE_NOTARY_KEY`, `FOLIO_APPLE_NOTARY_KEY_ID`, `FOLIO_APPLE_NOTARY_ISSUER` | Apple notarization credentials |

The job signs and notarizes the app and DMG, stages the packages in a release draft, verifies the stored bytes, and checks the public download URLs. Re-run the original workflow if publication stops partway so the job can reuse the retained signed packages. If those artifacts have expired, recover the exact packages before proceeding.

## Automatic previews

A successful `main` CI run creates a preview tag when the release paths change.
Folio derives the tag from the base version in `.release/units/folio.json`, the
commit timestamp, and the short SHA. The workflow token creates the tag and
dispatches the release workflow on that exact ref. Preview releases remain
prereleases and use their own Sparkle key, app identity, and ad hoc signature.

Set the corresponding Sparkle variable and secret in `folio-macos-preview`.
Public previews check GitHub Releases without a token. The original
`preview-v0.1.0` package requires a manual upgrade to a signed-update preview.

If your installed preview only recognizes `Folio-Preview-…zip` downloads,
install the Folio DMG that introduces support for the renamed archives once.
Replace `Folio.app` in Applications, then use **Settings → Updates** for later
previews.
