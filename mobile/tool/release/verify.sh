#!/usr/bin/env bash
# Checks published APKs of the free build against their source (openspec:
# add-fdroid-release, design decision 8). Run it from a checkout of the
# release's tag; it needs Docker or Podman and nothing of Kemlock's:
#
#   mobile/tool/release/verify.sh <tag> <published.apk>...
#
# It builds the release container from this checkout, rebuilds the tag in it
# with build.sh, checks that each APK is signed by Kemlock's release key
# (release-key.sha256), and copies its signature onto the rebuild of the same
# processor type with apksigcopier, as F-Droid does. For each it prints
# "match" when the two are the same file, or names the files inside that
# differ, or says the key is not Kemlock's; it exits non-zero unless every one
# matched. REPO is where to clone the tag from, by default this checkout's
# repository.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
[ $# -ge 2 ] || { echo "usage: $0 <tag> <published.apk>..." >&2; exit 2; }
tag="$1"
shift
repo="${REPO:-$root}"
engine="${CONTAINER_ENGINE:-docker}"

expected="${KEMLOCK_RELEASE_KEY_SHA256:-$(grep -v '^#' "$here/release-key.sha256" | tr -d '[:space:]')}"
if [ -z "$expected" ] || [ "$expected" = unset ]; then
  echo "verify.sh: release-key.sha256 records no release key yet" >&2
  exit 3
fi

# One image per version of the environment's files, so a checkout of an older
# tag builds in its own environment.
image="kemlock-release:$(cat "$here/Containerfile" "$here/tools.sha256" "$here/tree_sum.sh" "$here/build.sh" | sha256sum | cut -c1-12)"
"$engine" image inspect "$image" >/dev/null 2>&1 || "$engine" build -t "$image" -f "$here/Containerfile" "$here"

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
chmod 777 "$out"
names=()
for apk in "$@"; do
  names+=("$(basename "$apk")")
  cp "$apk" "$out/published-${#names[@]}.apk"
done
chmod 644 "$out"/published-*.apk

# Git Bash would rewrite the container paths as Windows paths.
export MSYS_NO_PATHCONV=1
# and Docker on Windows takes Windows paths.
if command -v cygpath >/dev/null 2>&1; then
  repo="$(cygpath -w "$repo")"
  out_mount="$(cygpath -w "$out")"
else
  out_mount="$out"
fi
"$engine" run --rm -v "$repo:/repo:ro" -v "$out_mount:/out" "$image" bash -c '
  set -uo pipefail
  build_tools=$ANDROID_HOME/build-tools/36.0.0
  # apksigcopier runs apksigner to check the copy it makes
  export PATH="$build_tools:$PATH"
  tag="$1"
  expected="$2"
  shift 2
  /home/vagrant/tools/build.sh "$tag" /repo >/out/build.log 2>&1 || { tail -40 /out/build.log; exit 5; }
  cd /out
  # Each entry outside META-INF with its CRC-32, by name.
  entries() { unzip -v "$1" | awk "NR > 3 && \$8 != \"\" && \$8 !~ /^META-INF\\// { print \$7, \$8 }" | sort -k2; }
  failed=0
  n=0
  for name in "$@"; do
    n=$((n + 1))
    published="published-$n.apk"
    signer="$("$build_tools/apksigner" verify --print-certs "$published" 2>/dev/null | sed -n "s/^Signer #1 certificate SHA-256 digest: //p")"
    if [ "$signer" != "$expected" ]; then
      echo "$name: not Kemlock'"'"'s key: signed by ${signer:-no valid key}, and the repo records $expected"
      failed=1
      continue
    fi
    abi="$(unzip -Z1 "$published" | sed -n "s|^lib/\([^/]*\)/libflutter.so$|\1|p" | head -1)"
    rebuilt="$(ls kemlock-*-"$abi"-unsigned.apk)"
    # --unsigned: the rebuild is unsigned, and only the published signature, copied onto it, must verify
    if apksigcopier compare --unsigned "$published" "$rebuilt" >/dev/null 2>&1; then
      echo "$name: match, the rebuild of $tag ($rebuilt) signed by Kemlock'"'"'s key"
    else
      echo "$name: no match; these files differ from the rebuild of $tag:"
      diff <(entries "$published") <(entries "$rebuilt") | sed -n "s/^[<>] [0-9a-f]* /  /p" | sort -u
      failed=1
    fi
  done
  exit $failed
' verify "$tag" "$expected" "${names[@]}"
