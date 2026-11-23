#!/usr/bin/env bash
# Runs a command against mobile/ in a Flutter container, for machines
# without Flutter. The container works on a copy of mobile/, so several
# runs can go at once and nothing is written back, except with --write.
#
#   tool/docker/flutter.sh 'flutter analyze && flutter test'
#   tool/docker/flutter.sh 'flutter test test/features/packing'
#   tool/docker/flutter.sh --write 'dart format lib test'
#   OUT=/some/dir tool/docker/flutter.sh 'flutter test --dart-define=SCREENSHOTS=true \
#     --update-goldens test/screenshots; cp test/screenshots/goldens/*.png /out/'
#   tool/docker/flutter.sh --clean     # removes every container these runs left
#
# The first run builds the image (about 2 GB). Packages are kept in the
# kemlock-pubcache volume; set ONLINE=1 after changing pubspec.yaml.
#
# Each container is capped at FLUTTER_CPUS (4) and FLUTTER_MEMORY (6g), so
# runs side by side leave the machine usable, and stops itself after
# FLUTTER_TIMEOUT seconds (1800). It is removed when this script ends or
# is interrupted: killing the docker client alone leaves its container
# running.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mobile="$(cd "$here/../.." && pwd)"
image=kemlock-flutter:3.47.7
label=kemlock-flutter

if [ "${1:-}" = "--clean" ]; then
  ids="$(docker ps -aq --filter "label=$label")"
  [ -z "$ids" ] || docker rm -f $ids >/dev/null
  echo "removed $(echo "$ids" | grep -c . || true) container(s)"
  exit 0
fi

write=0
if [ "${1:-}" = "--write" ]; then
  write=1
  shift
fi
[ $# -eq 1 ] || { echo "usage: $0 [--write] '<command>' | --clean" >&2; exit 2; }

docker image inspect "$image" >/dev/null 2>&1 || docker build -t "$image" -f "$here/Containerfile" "$here"

offline=--offline
[ "${ONLINE:-}" = "1" ] && offline=

# Git Bash would rewrite the container paths below as Windows paths.
export MSYS_NO_PATHCONV=1
out="${OUT:-$mobile/build/out}"
mkdir -p "$out"

name="$label-$$-$RANDOM"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

# docker runs in the background and the script waits for it, because bash
# runs a trap only after its foreground command ends: an interrupt has to
# reach cleanup while the container is still going.
run() {
  docker run --rm --init --name "$name" --label "$label" \
    --cpus "${FLUTTER_CPUS:-4}" --memory "${FLUTTER_MEMORY:-6g}" \
    -v kemlock-pubcache:/pub-cache "$@" &
  wait $!
}

limit="${FLUTTER_TIMEOUT:-1800}"
if [ "$write" = "1" ]; then
  # In place, for the formatter; the package config it needs is removed after.
  run -v "$mobile:/src" "$image" \
    timeout -k 10 "$limit" bash -c "set -e; flutter pub get $offline >/dev/null; trap 'rm -rf .dart_tool' EXIT; $1"
else
  run -v "$mobile:/src:ro" -v "$out:/out" "$image" \
    timeout -k 10 "$limit" bash -c "set -eo pipefail; mkdir -p /w; tar -C /src --exclude=./build --exclude=./.dart_tool -cf - . | tar -C /w -xf -; cd /w; flutter pub get $offline >/tmp/pub.log 2>&1 || { cat /tmp/pub.log; exit 1; }; $1"
fi
