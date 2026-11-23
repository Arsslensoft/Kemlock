#!/usr/bin/env bash
# Builds the free build's APKs of one tag, the way every release is built
# (openspec: add-fdroid-release, design decision 6). It runs in the release
# container (Containerfile) as the user vagrant:
#
#   build.sh <tag> [<repo>]
#
# <repo> is a git URL, or the path of a repository mounted in the container
# (by default /repo). The tag is cloned to F-Droid's path, switched to the
# free build, and built from nothing but the public repo: no --dart-define,
# no key. The three unsigned APKs and their SHA256SUMS land in
# /out.
set -euo pipefail

tag="${1:?usage: build.sh <tag> [<repo>]}"
repo="${2:-/repo}"
src=/home/vagrant/build/com.kemlock.app
out=/out

rm -rf "$src"
git clone --quiet --no-checkout "$repo" "$src"
git -C "$src" -c advice.detachedHead=false checkout --quiet "refs/tags/$tag"
cd "$src/mobile"

tool/build/use_free.sh
printf 'sdk.dir=%s\nflutter.sdk=%s\n' "$ANDROID_HOME" "$FLUTTER_ROOT" > android/local.properties
flutter pub get --enforce-lockfile
flutter build apk --release --split-per-abi

version="$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)"
mkdir -p "$out"
rm -f "$out"/kemlock-*.apk "$out/SHA256SUMS"
for abi in armeabi-v7a arm64-v8a x86_64; do
  cp "build/app/outputs/flutter-apk/app-$abi-release.apk" "$out/kemlock-$version-$abi-unsigned.apk"
done
dart run tool/release/check_free.dart "$out"/kemlock-*.apk
(cd "$out" && sha256sum kemlock-*.apk > SHA256SUMS && cat SHA256SUMS)
