#!/usr/bin/env bash
# Switches this checkout of mobile/ to the free build (openspec:
# add-fdroid-release, design decision 2): pubspec_overrides.yaml points
# kemlock_parts at packages/parts_free, and pubspec.free.lock, the free
# build's committed lockfile, takes pubspec.lock's place. Then
#
#   flutter pub get --enforce-lockfile
#
# proves the lockfile fits. The release container and F-Droid's recipe run
# this in a checkout they throw away. To go back to the store build:
#
#   rm pubspec_overrides.yaml && git checkout pubspec.lock
#
# tool/build/use_free.dart does the same where there is no bash.
set -euo pipefail

mobile="$(cd "$(dirname "$0")/../.." && pwd)"

cat > "$mobile/pubspec_overrides.yaml" <<'YAML'
# Written by tool/build/use_free.sh: the free build's parts, in place of the
# store build's (openspec: add-fdroid-release). Not in git.
dependency_overrides:
  kemlock_parts:
    path: packages/parts_free
YAML
cp "$mobile/pubspec.free.lock" "$mobile/pubspec.lock"
echo "Switched to the free build; now run: flutter pub get --enforce-lockfile"
