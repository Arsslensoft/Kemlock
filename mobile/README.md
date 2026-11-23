# Kemlock for iOS and Android

The Flutter app. It replaced the React and Capacitor app that was at the root
of this repository (last built at abcb758, in the history archived when the repository restarted
on 2026-11-23), as
`../docs/plans/flutter-rewrite.md` describes, and keeps the vault in the same
native storage keys. Its app id is `com.kemlock.app`, not the Capacitor app's
`com.backmycodes.app`, so the stores treat it as a new app: a vault moves over
through an encrypted export.

Kemlock is free and open source (GPLv3), and every feature is free in every build: there is
no subscription, no in-app purchase and no ads.

## Running it

Needs Flutter 3.47 (Dart 3.13). Builds for phones need the Android SDK, and
a Mac with Xcode for iOS.

```sh
flutter run
flutter build appbundle
flutter build ipa
```

An Android release is signed with the key `android/key.properties` names, a
file git ignores:

```properties
storeFile=/path/to/upload-keystore.jks
storePassword=…
keyAlias=upload
keyPassword=…
```

Without it, a release build is unsigned. To try a release build on a phone
without the real key, sign it with the debug key by passing
`-Pkemlock.signReleaseWithDebugKey=true` to Gradle, or by putting
`kemlock.signReleaseWithDebugKey=true` in `~/.gradle/gradle.properties`. Never
hand out a build signed that way: the debug key sits in
`~/.android/debug.keystore` under the well-known password `android`, and a
phone accepts any update signed with the same key as the installed app.

An iOS build for a phone or the App Store is signed by the Apple team
`ios/Signing.xcconfig` names, another file git ignores:

```sh
cp ios/Signing.example.xcconfig ios/Signing.xcconfig   # then put in your team's ID
```

Xcode signs the app and both extensions automatically with that team, and
the first time registers their app ids, the App Group and the capabilities
their entitlements ask for. Don't choose the team in Xcode's Signing &
Capabilities tab instead: that writes it into `project.pbxproj`. Without the
file a simulator build still works.

## Checking it

```sh
flutter analyze
flutter test
```

Both run on the Flutter SDK alone, so they also run in Docker, without the
Android SDK or Xcode. Where Flutter isn't installed, `tool/docker/flutter.sh`
builds an image with Flutter 3.47.7 and runs a command on a copy of
`mobile/`:

```sh
tool/docker/flutter.sh 'flutter analyze && flutter test'
tool/docker/flutter.sh --write 'dart format lib test'
tool/docker/flutter.sh --clean   # removes containers a cut-short run left
```

Each container is capped at 4 CPUs and 6 GB and stops itself after 30
minutes; run one at a time where the machine is shared.

`test/screenshots` renders screens to PNG, for looking at the design without
a phone:

```sh
flutter test --dart-define=SCREENSHOTS=true --update-goldens test/screenshots
```

The PNGs land in `test/screenshots/goldens`, which git ignores.

## Compatibility

Everything other versions, other devices or other people read stays byte
for byte what the TypeScript app writes: the vault, exports, QR transfers,
sync files, invites and Recovery Kit pieces. `test/fixtures` holds files
the TypeScript app made, and the Dart tests open them. They were written by
Node scripts that ran against that app; the scripts and the app are in the
archived history at abcb758, which is where to make a new fixture from. A fixture the
Dart code wrote proves nothing about the old format.
`test/fixtures/legacy-v0.1.0.json` comes from app v0.1.0 and is never
regenerated.

Comments in `lib` and `test` that name a `src/` file mean the TypeScript app
as it was at abcb758 in the archived history.

## Layout

- `lib/core`: the key-value store on Capacitor's preferences, ids, the
  clock and the second ticker, toasts.
- `lib/crypto`: SHA-3, PBKDF2, scrypt, ML-KEM-1024 and AES-256-GCM.
- `lib/vault`: the vault, its registry of several vaults, exports, QR
  transfers, biometric unlock and the controller the screens use.
- `lib/models`: accounts and backup services, in the JSON the vault holds.
- `lib/features`: one folder per feature, with its logic, providers and
  screens.
- `lib/platform`: the camera, files, the clipboard, links and printing,
  behind providers that tests replace with the fakes in `test/fakes`.
- `lib/app`, `app.dart`, `router.dart`: the shell, the vault gate, the tab
  bar, the look and auto-lock.
- `lib/ui`: the design system: theme tokens, motion and shared widgets.
  The decorative effects (ambient light, sheen, glow, border light, scan line, reveal) are in
  `lib/ui/theme/effects.dart`, on the loop driver of `lib/ui/theme/loop.dart`; under the phone's
  reduce-motion setting none of them moves, and nothing they decorate depends on them.
- `lib/i18n` and `assets/i18n`: the copy, the same message ids in `en.json` and `fr.json`.
- `assets/data`: the 2FA directory and the service logos, both copied from
  the TypeScript app (the logos are `simple-icons` paths, CC0).
- `tool`: the Docker image and the app icons (`tool/icons/build_svgs.mjs` writes
  the logo masters in `assets/brand`, and `tool/icons/render.sh` draws the icons
  from them).
