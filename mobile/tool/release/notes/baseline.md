# Baseline: what differs between two builds before any setting

Task 1.3 of `add-fdroid-release`, 2026-11-17. The free build of commit f1eecb66 (the store
build of 5a0bef69 does not build for release: see below), built with
`flutter build apk --release --split-per-abi` twice in the release container
(`kemlock-fdroid-release:probe`, from this folder's Containerfile), each time in a fresh
container from a clean clone, at two paths:

- `/home/vagrant/build/com.kemlock.app` (F-Droid's)
- `/home/vagrant/elsewhere/deeper/com.kemlock.app`

The three pairs of APKs are the same size and differ. `diffoscope` names the same entries
in each pair:

| Entry | What differs |
|---|---|
| `lib/<abi>/libapp.so` | The Dart AOT snapshot holds the path of `.dart_tool/flutter_build/dart_plugin_registrant.dart`, a `file:` URI under the build's path, and its GNU build ID; the longer path shifts everything after it |
| `lib/<abi>/libdartjni.so` | The jni package's bridge, compiled by the NDK at build time: its GNU build ID, which hashes the build's paths |
| the zip's central directory | The CRC-32 of the two entries above |

for `<abi>` each of `armeabi-v7a`, `arm64-v8a` and `x86_64`. Nothing else differs:
`classes.dex`, `resources.arsc`, `AndroidManifest.xml`, Flutter's assets and the other
native libraries (Flutter's engine, AndroidX's) are the same byte for byte, and every entry
is dated 1981-01-01 01:01:02 by the Android Gradle plugin.

So every difference comes from the build's path, which `build.sh` and F-Droid's build
server fix at `/home/vagrant/build/com.kemlock.app`. Group 4 checks that two builds at that
path agree (`reproducibility.md`).

The store build of 5a0bef69 could not be the baseline: `flutter build apk --release` stops
in R8 on classes of ML Kit's text recognition for other scripts
(`com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions` and the Devanagari,
Japanese and Korean ones), which `google_mlkit_text_recognition` refers to and the app does
not include. This was so before this change; the store build's release needs `-dontwarn`
rules for those packages (the plugin's README gives them) or the four script libraries.
