# Contributing to Kemlock

Thank you for helping. Kemlock is a post-quantum encrypted authenticator and password manager for
iOS and Android, written in Flutter, and free software under the
[GNU GPL v3 or later](LICENSE). People keep their one-time codes, passwords and keys in it, so the
rules below are strict about two things: a change must be one that can be reviewed, and it must not
change what is already on people's phones.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). To report a
vulnerability, don't open an issue: follow the [security policy](.github/SECURITY.md).

## Before you start

- **Bugs and ideas**: search the [issues](https://github.com/Arsslensoft/Kemlock/issues) first, then
  open one with the bug report or feature request form. For a question, see [SUPPORT.md](SUPPORT.md).
- **A change that is more than a small fix**: open an issue, or comment on one, and say what you
  plan, before you write it. A new feature, a new format, or a new dependency is easier to accept
  when it was agreed first. Plans of larger changes live in [`docs/plans`](docs/plans).
- **Where things are**: `mobile/` is the Flutter app, with its tests and its `android` and `ios`
  projects. Run Flutter commands from `mobile/`. See [CLAUDE.md](CLAUDE.md) for the layout, and
  [`mobile/README.md`](mobile/README.md). The browser extension has its own repository,
  [Kemlock-browser](https://github.com/Arsslensoft/Kemlock-browser), and the server its own,
  [Kemlock-Server](https://github.com/Arsslensoft/Kemlock-Server).

## Set up

You need the Flutter SDK, version 3.47.7 (the one CI uses), and, for the native code, the Android
SDK with a JDK 17 and Xcode with the iOS 26.2 SDK or later. Where Flutter isn't installed,
`mobile/tool/docker/flutter.sh '<command>'` runs a command against `mobile/` in a container.

```bash
cd mobile
flutter pub get --enforce-lockfile
```

## Run the checks

CI runs all of these on every pull request ([`ci.yml`](.github/workflows/ci.yml)); please run them
before you push.

```bash
cd mobile

# Format. The page width, 140, comes from analysis_options.yaml: don't pass -l.
dart format --output=none --set-exit-if-changed lib test packages tool/build tool/release

# Analyze, and test. The parts of each build are analyzed and tested with that build.
flutter analyze && flutter analyze packages/parts_store
flutter test && flutter test packages/parts_store/test

# The Kotlin tests (autofill and the credential transfer plugin), on the JVM, with the dependency
# checksums verified.
cd android
./gradlew --dependency-verification strict :app:testDebugUnitTest :app:lintDebug :credential_transfer:testDebugUnitTest
```

On a Mac, the Swift tests: `flutter build ios --simulator --debug --no-codesign`, then
`xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner -only-testing:RunnerTests` on a
simulator (`.github/workflows/ci.yml` has the exact command). The pure-Dart crypto tests also run
in a browser under dart2wasm. From `mobile/`: `cp tool/test/dart_test.wasm.yaml dart_test.yaml && dart test -p chrome -c dart2wasm -t wasm; rm dart_test.yaml` (`flutter test` rejects a browser platform in `dart_test.yaml`, so the file only sits there for this run).

A test that checks a fix goes in the same commit as the fix. Any other test goes in its own
`test(scope)` commit after the code it checks. The whole-app flows run as widget tests through the
real router, with fakes for the camera, biometrics and the store, so a change to a screen usually
has a test in `mobile/test/flows` or beside the feature.

## The store build and the free build

Kemlock is built twice from one tree. The **store build** is `mobile/pubspec.lock` as checked out,
with the closed parts the stores need (`mobile/packages/parts_store`: ML Kit, Play billing, and so
on). The **free build**, for F-Droid and the releases page, swaps those for free ones
(`mobile/packages/parts_free`) and has its own lockfile, `mobile/pubspec.free.lock`. CI checks
both, and a release is built twice from the free build and compared byte for byte
([docs/reproducible-builds.md](docs/reproducible-builds.md)).

```bash
cd mobile
tool/build/use_free.sh                  # the free build's parts and lockfile are in place
flutter pub get --enforce-lockfile
flutter analyze && flutter analyze packages/parts_free
flutter test && flutter test packages/parts_free/test
flutter build apk --debug               # then: dart run tool/release/check_free.dart build/app/outputs/flutter-apk/app-debug.apk

rm pubspec_overrides.yaml && git checkout pubspec.lock   # back to the store build
```

**When you change a dependency**, both lockfiles must change, in the same commit as the change:

1. In the store build, `flutter pub get`, and commit `pubspec.lock`. Stage it first
   (`git add pubspec.lock`), so the last step below doesn't undo it.
2. `tool/build/use_free.sh`, then `flutter pub get` (without `--enforce-lockfile`), then
   `cp pubspec.lock pubspec.free.lock`, then `rm pubspec_overrides.yaml && git checkout pubspec.lock`.
   Check that `tool/build/use_free.sh && flutter pub get --enforce-lockfile` passes.
3. If an Android dependency changed, add its checksums to Gradle's verification file:
   `cd android && ./gradlew --write-verification-metadata sha256 :app:testDebugUnitTest :app:lintDebug :credential_transfer:testDebugUnitTest :app:assembleDebug`,
   and the same with `:app:assembleDebug` alone after `tool/build/use_free.sh`. Read the diff to
   `android/gradle/verification-metadata.xml`: every new line is a file you are trusting.

Dependabot's pull requests get these refreshed for them. A new dependency's licence must be one a
GPL-3.0-or-later program may use (MIT, BSD, Apache-2.0, ISC, MPL-2.0, LGPL, GPL 3 and the like): the
Licences check fails otherwise, and a reviewed exception goes in `tool/ci/license-overrides.json`
with the reason. The free build may hold no closed or store-only code; `check_free.dart` checks the
APK for it.

## Formats and fixtures: the rule that matters most

What other versions and other people read (the vault, exports, QR transfers, sync files, invites,
Recovery Kit pieces, and the Kemlock account formats) must stay **byte for byte** what past versions
wrote, or vaults and backups already on people's phones stop opening. The files the earlier app made
are in `mobile/test/fixtures`, and the Dart tests open them.

- **Never regenerate a fixture** to make a test pass, and never edit one. `legacy-v0.1.0.json` above
  all. If a fixture test fails after your change, or after a dependency upgrade, your change is what
  is wrong, or the format needs a new version that the old one still opens; it is not the fixture.
- The server's vectors under `mobile/test/fixtures/server` are copied by
  `mobile/tool/server/copy_vectors.sh` and checked against their `SHA256SUMS`. Don't edit them by
  hand.
- **Names stay as they were.** The app was called BackMyCodes until November 2026, and the old name
  stays wherever a file or stored key carries it (`"app": "BackMyCodes"`, the `backmycodes_` storage
  keys, `backmycodes-sync.json`, the `BMCKIT1-` and `bmc-space:` prefixes). Don't rename those.
- A new format gets known-answer vectors of its own, written when it is written, and they are never
  regenerated either.

## Commits

Commit one change at a time. Each feature, fix, test, chore, docs change or refactor gets its own
commit; never lump unrelated work into one commit like "fix" or "refactoring". The pull request
checks below, and a reviewer, will ask you to split one.

**Conventional Commits.** The message is
[`type(scope): what the change does`](https://www.conventionalcommits.org/en/v1.0.0/#specification),
in plain words, lowercase after the colon, no trailing period.

- Types: `feat`, `fix`, `test`, `chore`, `docs`, `refactor`, `revert`. Add `!` before the colon for
  a breaking change.
- The scope is the area touched: `accounts`, `backup`, `breaches`, `sync`, `vault`, `keys`, `notes`,
  `settings`, `lock`, `setup`, `export`, `import`, `qr`, `crypto`, `storage`, `clipboard`,
  `autofill`, `passkeys`, `passwords`, `subscription`, `paywall`, `i18n`, `theme`, `ui`, `android`,
  `ios`, `pwa`, `deps`, `lint`, and `mobile` for the app as a whole. The repository around the app
  has `ci` (workflows and tooling), `repo` (files at its root), `release` and `security`.
- The body, wrapped at about 72 columns, says what was wrong or missing and why the change fixes
  it. Name other commits by their short hash.
- Lockfile and dependency changes go in with the feature that needs them, or in their own
  `chore(deps)` commit.

```text
feat(backup): show a vault health card on the Backup tab
fix(qr): read a vault QR that was exported before the format bump
test(crypto): decrypt the vault fixtures of every past version
chore(deps): update go_router to 18.2
```

**Sign off every commit.** Kemlock uses the [Developer Certificate of Origin](https://developercertificate.org)
(DCO), not a contributor licence agreement: by signing off you say that you wrote the change, or
have the right to submit it, under the project's licence. Add `-s` when you commit:

```bash
git commit -s -m "fix(qr): read a vault QR that was exported before the format bump"
```

That adds `Signed-off-by: Your Name <you@example.com>`, with the name and email of your git
configuration, which must be the commit's author. To add it to commits you already made:
`git rebase --signoff HEAD~3` (for the last three), then `git push --force-with-lease`. The DCO
check fails a pull request whose commits aren't signed off by their authors.

**Work done with an AI tool.** You are the author and answer for the change: read it, run it, and
sign it off yourself; a tool can't certify the DCO for you. Say which tool helped with an
`Assisted-by: <model> via <tool>` footer, for example `Assisted-by: Claude Opus 5.5 via Claude Code`,
and don't add a `Co-Authored-By` line for it.

To split a working tree into commits, stage whole files, or a file's hunks with `git apply --cached`
on a patch (`git add -p` is interactive). Don't rewrite pushed history of `main`.

## Pull requests

1. Fork the repository (or branch, with write access), and branch from `main`:
   `fix/vault-qr-old-format`.
2. Make your commits as above, and run the checks.
3. Open the pull request against `main` and fill in its template. Its **title** is a Conventional
   Commit too, since it becomes the commit when the pull request is squash-merged and then the line
   in [`CHANGELOG.md`](CHANGELOG.md).
4. CI runs: **CI gate**, **DCO**, **Conventional Commits**, **Licences**, **REUSE**, the secret scan,
   dependency review and CodeQL. A maintainer reviews it (the files of the cryptography and the
   formats get a closer look, per [CODEOWNERS](.github/CODEOWNERS)), and CodeRabbit comments first.
   Answer the comments by pushing new commits; the maintainer squash-merges.
5. Keep it small. A pull request that does one thing is reviewed and merged faster than one that does
   five.

## Licensing

Kemlock is under the [GPL v3 or later](LICENSE), and your contribution is too: the DCO is your
statement of that. The repository follows the [REUSE](https://reuse.software) specification:
[`REUSE.toml`](REUSE.toml) says which licence each file is under, and the REUSE check fails a file
it doesn't cover. New third-party data, fonts or code need their licence named there, a credit in
the README's "Bundled data and assets", and a licence that allows a GPL-3.0-or-later program to
carry it.

## Releases

Releases are made by the owner. [release-please](https://github.com/googleapis/release-please)
keeps a release pull request open on `main` that writes `CHANGELOG.md` from the commits and
proposes the next version; merging it tags the version, which starts the release build described in
[docs/reproducible-builds.md](docs/reproducible-builds.md). The signing keys are never in CI.
