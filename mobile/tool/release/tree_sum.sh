#!/usr/bin/env bash
# The checksums of the tools the release container installs (openspec:
# add-fdroid-release, design decision 7): one SHA-256 per tree, over the path,
# the contents and the executable bit of each file and the target of each
# link, so two installs agree only when every file does. Times and owners
# are left out; they differ from one install to the next.
#
#   tree_sum.sh                     prints the sum of every tree below
#   tree_sum.sh --check FILE        fails, naming the tree, when one differs
set -euo pipefail

: "${ANDROID_HOME:?}" "${FLUTTER_ROOT:?}"

trees=(
  "$ANDROID_HOME/platforms/android-37.0"
  "$ANDROID_HOME/platforms/android-36"
  "$ANDROID_HOME/platforms/android-35"
  "$ANDROID_HOME/platforms/android-34"
  "$ANDROID_HOME/build-tools/36.0.0"
  "$ANDROID_HOME/build-tools/34.0.0"
  "$ANDROID_HOME/ndk/28.2.13676358"
  "$ANDROID_HOME/cmake/3.22.1"
  "$ANDROID_HOME/platform-tools"
  "$FLUTTER_ROOT/bin/cache/artifacts"
)

sum_of() {
  [ -d "$1" ] || { echo "tree_sum: $1 is not installed" >&2; return 1; }
  (
    cd "$1"
    find . -type l -printf 'link %p %l\n'
    find . -type f -perm /111 -printf 'exec %p\n'
    find . -type f -print0 | xargs -0 -r sha256sum | sed 's/^\([0-9a-f]*\)  /file \1 /'
  ) | LC_ALL=C sort | sha256sum | cut -d' ' -f1
}

name_of() {
  case "$1" in
    "$ANDROID_HOME"/*) echo "android-sdk/${1#"$ANDROID_HOME"/}" ;;
    "$FLUTTER_ROOT"/*) echo "flutter/${1#"$FLUTTER_ROOT"/}" ;;
  esac
}

if [ "${1:-}" = "--check" ]; then
  expected="$2"
  failed=0
  for tree in "${trees[@]}"; do
    name="$(name_of "$tree")"
    want="$(awk -v n="$name" '$2 == n { print $1 }' "$expected")"
    got="$(sum_of "$tree")"
    if [ "$want" != "$got" ]; then
      echo "tree_sum: $name is $got, expected ${want:-nothing recorded}" >&2
      failed=1
    fi
  done
  exit "$failed"
fi

for tree in "${trees[@]}"; do
  echo "$(sum_of "$tree")  $(name_of "$tree")"
done
