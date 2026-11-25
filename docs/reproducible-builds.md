# Checking a build of Kemlock

Kemlock's source is public so that anyone can read what the app does. This page is the
other half: how anyone can check that an APK of Kemlock was built from that source and
nothing else, by building it again and getting the same file.

## What this covers, and what it does not

**Covered: the free build's Android APKs.** The free build is Kemlock made only of free
software, published on the repo's releases page and on F-Droid. Each of its releases can be
rebuilt from its tag, in the environment described below, into APKs identical byte for byte
to the published ones once the signature is set aside. There is one APK per processor type
(`armeabi-v7a`, `arm64-v8a`, `x86_64`), and each is covered.

**Covered too: the browser extension's zips**, for Chrome, Edge and Firefox. They are rebuilt
more simply, as [the browser extension](#the-browser-extension) below says.

**Not covered: the build Google Play delivers, and the iOS build.** These cannot be compared
byte for byte with anything a stranger builds, so they are not called reproducible here:

- Google Play gets an app bundle, not an APK. Google re-signs the APKs it cuts from it, with
  a key Google holds, and changes them as it delivers them to each phone. No one outside
  Google gets the file the owner uploaded back, or can tell which bytes Google changed.
- The App Store encrypts every app it delivers, and the decrypted file is not available to
  check.

The store build is built from the same tag, and the checksum of its bundle is published
with each release, but what reaches a phone from either store cannot be checked this way.

## The two builds

The store build and the free build are the same app, with the same vault, exports, sync
files, invites and Recovery Kit pieces. Three parts differ:

| | Store build | Free build |
|---|---|---|
| QR scanning | `mobile_scanner` (Google ML Kit on Android) | Flutter's `camera` plugin and `zxing2`, a Dart port of ZXing |
| Backup codes from pictures and PDFs | ML Kit's text recognition and PDFium (`pdfrx`) | Not offered: text files, pasting and typing only |
| System credential transfer and APNs push | The system credential hand-off; APNs push on iOS | Not offered: no Google Play services, no APNs |

The free build sends nothing to Google. The breach check and the
password leak check ask Have I Been Pwned, only when turned on, and sync talks only to a
server the person names, as in the store build.

The code of the parts that differ is in `mobile/packages/parts_store` and
`mobile/packages/parts_free`; `mobile/tool/build/use_free.sh` switches a checkout to the
free build.

## The build environment

A release is built in one container, described completely in
[`mobile/tool/release/Containerfile`](../mobile/tool/release/Containerfile):

- Debian 12 (bookworm), the image named by its digest, with its packages (OpenJDK 17
  among them) from one day's snapshot of Debian's archive;
- the Android command-line tools by SHA-256, and the SDK platforms, build tools, NDK
  28.2.13676358, CMake and platform tools at fixed versions, each installed tree checked
  against [`tools.sha256`](../mobile/tool/release/tools.sha256);
- Flutter 3.47.7 by its published SHA-256, and its engine's Android files, checked the same
  way;
- the Dart packages fixed by `pubspec.free.lock`, enforced; the Gradle distribution by its
  SHA-256 in `gradle-wrapper.properties`; every Maven artifact by its SHA-256 in
  `android/gradle/verification-metadata.xml`.

A tool or dependency that no longer matches its recorded checksum stops the build with an
error naming it. The build reads nothing of the moment or the machine, and no secret,
account or key: [`build.sh`](../mobile/tool/release/build.sh) clones the tag to
`/home/vagrant/build/com.kemlock.app`, the path F-Droid's build server uses, and builds it
with nothing but the public repo.

## Checking a release

With Docker (or Podman, `CONTAINER_ENGINE=podman`) installed, from a checkout of the
release's tag:

```bash
git clone https://github.com/kemlock/kemlock.git && cd kemlock
git checkout v1.2.0
mobile/tool/release/verify.sh v1.2.0 ~/Downloads/kemlock-1.2.0-arm64-v8a.apk
```

It rebuilds the tag, checks the APK is signed by Kemlock's release key, and copies the
APK's signature onto its own build, as F-Droid does. It prints `match` when the two are the
same file. Otherwise it names the files inside the APK that differ, or says the key is not
Kemlock's, and exits with an error. Several APKs of the release can be given at once; each
is checked against the one rebuild. The first run builds a container of about 11 GB and
takes about an hour; later runs reuse the container.

## The release key

Every APK of the free build, on the releases page and on F-Droid alike, is signed with one
release key, which never changes and is never given to an automated build. The owner signs
each release on their own machine after it is built, with
[`sign.sh`](../mobile/tool/release/sign.sh); the signed file is the built file with a
signature added and nothing else changed.

The SHA-256 of the release key's certificate:

```text
(not made yet: the owner makes the key before the first release)
```

It is also in [`mobile/tool/release/release-key.sha256`](../mobile/tool/release/release-key.sha256),
which `verify.sh` reads. To see who signed an APK you hold:

```bash
apksigner verify --print-certs kemlock-1.2.0-arm64-v8a.apk
```

and compare the `certificate SHA-256 digest` with the one above. Each release also lists the
SHA-256 of every file in its `SHA256SUMS`; `sha256sum -c SHA256SUMS` checks a download.

If the release key were ever lost, no update could be signed for the free build. People
would then export their vaults, install the build under the new key and import them, as in
the next section.

## Moving between the two builds

The two builds are signed with different keys (Google Play signs the store build with a key
Google holds), so a phone refuses to install one over the other, and nothing in the vault is
changed when it does. To move from the store build to the free build, or back:

1. In the build you have, Settings › Export: make an **encrypted** export and keep the file
   and its password.
2. Uninstall that build. This removes its vault from the phone.
3. Install the other build, from the releases page, F-Droid or a store.
4. In Settings › Import, open the file with its password. Every account, backup code, key,
   note and passkey comes back.

A vault that syncs can instead be set up again in the new build and synced down.

## The browser extension

The extension has its own repository,
[Kemlock-browser](https://github.com/Arsslensoft/Kemlock-browser). Its
`docs/reproducible-builds.md` says how to rebuild its zips and compare them with the
published ones.

## Releases, and who reproduced them

Before a release is published it is built twice, by two jobs on separate machines
([`.github/workflows/release.yml`](../.github/workflows/release.yml)), and the six APKs are
compared byte for byte. A release whose two builds differ stops there, with diffoscope's
report of what differs, and is not published. Only after the two agree is it drafted on the
releases page, unsigned, for the owner to sign.

A report that a published release cannot be rebuilt to the same file is a security report:
send it through the channels of the security policy, and it is answered in the times that
policy gives. Until the difference is explained, the release's entry below says it is
disputed.

| Release | Built twice in CI | Reproduced by, other than the owner | Date |
|---|---|---|---|
| none yet | | | |
