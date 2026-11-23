# Kemlock

A post-quantum encrypted authenticator for iOS and Android, written in Flutter. It replaced a
React, Vite and Capacitor app (`docs/plans/flutter-rewrite.md`); that app is gone from the tree and
last built at abcb758. The repository restarted from one commit on 2026-11-23; abcb758 and the rest of
the history before it are archived, and the maintainer keeps them as a git bundle.

The app was called BackMyCodes, with the app id `com.backmycodes.app`, until November 2026. It is
now Kemlock, `com.kemlock.app`, which the stores treat as a new app, and the Dart package is
`kemlock`. The old name stays wherever a file or stored key carries it, so files from any version
keep opening and the fixtures stay valid: `"app": "BackMyCodes"` in exports and sync files
(`formatAppName`), the `backmycodes_` storage keys, `backmycodes-sync.json` and
`backmycodes-space-<id>.json`, and the `BMCKIT1-` and `bmc-space:` prefixes. Don't rename those.

## Layout

- `mobile/`: the Flutter app, with its tests and the `android` and `ios` projects. Run Flutter
  commands from `mobile/`; where Flutter isn't installed, `mobile/tool/docker/flutter.sh` runs them
  in Docker.
- `docs/`: plans that are part of the repo. `/plans/` holds local notes and stays out of git.

The platform-free Dart (the crypto, the models, the vault store, the sync engines, OTP, the generator
and site matching) is in [Kemlock-core](https://github.com/Arsslensoft/Kemlock-core), checked out
next to this repository as `../kemlock-core` and pinned by commit in `mobile/pubspec.yaml` (both
lockfiles). Each moved file under `mobile/lib` is now one line exporting
`package:kemlock_core/<same path>`; change the code in Kemlock-core, then move the pin here. Its
platform halves (`*_io.dart`) and the seams the app fills (unlock keys, biometrics, the attachment
store, Vaultwarden's client details) are described there.

The browser extension is no longer here. It moved, with its history, to
[Kemlock-browser](https://github.com/Arsslensoft/Kemlock-browser), checked out next to this
repository as `../kemlock-browser`. It still reads the app's `mobile/lib/ui/theme/tokens.dart`,
`mobile/assets/i18n` and `mobile/assets/brand` from `../kemlock`, and it keeps its own copies of
`mobile/assets/fonts` and `mobile/test/fixtures/autofill/fields.json`. When those change here,
update the extension's copies too.

Formats other versions or people read (the vault, exports, QR transfers, sync files, invites,
Recovery Kit pieces) must stay byte for byte what the TypeScript app wrote, or vaults and backups
already on people's phones stop opening. The files it made are in `mobile/test/fixtures` and the
Dart tests open them; never regenerate `legacy-v0.1.0.json`. The scripts that wrote them ran
against the TypeScript app and are in the archived history at abcb758.

## Commits

Commit one change at a time, the way the amethyst (Amethystora) repo does. Each feature, fix, test,
chore, docs change or refactor gets its own commit; never lump unrelated work into one commit like
"fix" or "refactoring".

- Messages follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/#specification):
  `type(scope): what the change does`, in plain words, lowercase after the colon, no trailing period.
- Types: `feat`, `fix`, `test`, `chore`, `docs`, `refactor`, `revert`.
- The scope is the area touched: `accounts`, `backup`, `breaches`, `sync`, `vault`, `keys`, `notes`, `settings`, `lock`,
  `setup`, `export`, `import`, `qr`, `crypto`, `storage`, `clipboard`, `autofill`, `passkeys`, `passwords`, `subscription`,
  `paywall`, `i18n`, `theme`, `ui`, `android`, `ios`, `pwa`, `deps`, `lint`,
  `mobile` for the Flutter app as a whole, and, for the repository around the app, `ci` (workflows and
  tooling), `repo` (files at its root), `release` and `security`. A feature ported to the Flutter app keeps its area's scope and ends
  "in flutter", e.g. `feat(backup): show a vault health card in flutter`.
  `subscription` and `paywall` are historical: they mark the commits of the Premium feature, which was
  removed in November 2026 when Kemlock became entirely free. Nothing new uses them.
- A test goes in its own `test(scope)` commit, after the commit for the code it checks, unless it is
  the regression test of a fix, which goes in with the fix.
- Lockfile and dependency changes go in with the feature that needs them, or in their own
  `chore(deps)` commit.
- The body, wrapped at about 72 columns, says what was wrong or missing and why the change fixes it.
  Name other commits by their short hash.
- Every commit of a pull request is signed off by its author (`git commit -s`, the Developer
  Certificate of Origin): CONTRIBUTING.md explains it, and CI checks it. An agent leaves the sign-off to
  the person who submits the work.
- AI agents end the message with an `Assisted-by: <model> via <tool>` footer, e.g.
  `Assisted-by: Claude Opus 5.5 via Claude Code`, and no `Co-Authored-By` line.

Examples:

```text
feat(backup): show a vault health card on the Backup tab
fix(qr): read a vault QR that was exported before the format bump
test(crypto): decrypt the vault fixtures of every past version
chore(deps): update Capacitor to 7
```

To split a working tree, stage whole files, or a file's hunks with `git apply --cached` on a patch
(`git add -p` is interactive). Don't rewrite pushed history to split old commits unless asked.
