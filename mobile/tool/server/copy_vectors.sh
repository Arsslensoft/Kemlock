#!/usr/bin/env bash
# Copies the Kemlock server's published test vectors, as they are, into
# test/fixtures/server/ (docs/plans/add-account-crypto.md, design 9).
#
#   tool/server/copy_vectors.sh <path to the kemlock-server repo>
#
# The server's test-vectors/ folder (CC0-1.0) holds one JSON file per format
# and a SHA256SUMS file. This script copies the JSON files and SHA256SUMS
# without editing them, checks the copy against SHA256SUMS, and writes
# SOURCE.json with the repo, the commit and its date. The vectors are only
# ever refreshed by this script; test/crypto/account/vectors_checksum_test.dart
# fails on a file that was edited by hand.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <path to the kemlock-server repo>" >&2
  exit 2
fi

repo="$(cd "$1" && pwd)"
source_dir="$repo/test-vectors"
mobile="$(cd "$(dirname "$0")/../.." && pwd)"
dest="$mobile/test/fixtures/server"

if [ ! -f "$source_dir/SHA256SUMS" ]; then
  echo "no $source_dir/SHA256SUMS: the server has not published its vectors" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  check_sums() { sha256sum -c SHA256SUMS; }
else
  check_sums() { shasum -a 256 -c SHA256SUMS; }
fi

(cd "$source_dir" && check_sums >/dev/null)

mkdir -p "$dest"
find "$dest" -maxdepth 1 -type f \( -name '*.json' -o -name SHA256SUMS \) -delete
# Only the files SHA256SUMS lists: the server keeps other vectors (federation-*.json, with their own
# federation-SHA256SUMS) for server-to-server formats, which no client speaks.
cp "$source_dir/SHA256SUMS" "$dest/"
awk '{ name = $2; sub(/^\*/, "", name); print name }' "$source_dir/SHA256SUMS" | while read -r name; do
  cp "$source_dir/$name" "$dest/"
done
(cd "$dest" && check_sums >/dev/null)

commit="$(git -C "$repo" rev-parse HEAD)"
committed="$(git -C "$repo" show -s --format=%cI HEAD)"
cat > "$dest/SOURCE.json" <<JSON
{
  "repo": "kemlock-server",
  "commit": "$commit",
  "date": "$committed"
}
JSON

echo "Copied $(ls "$dest"/*.json | wc -l) files from $commit into $dest"
