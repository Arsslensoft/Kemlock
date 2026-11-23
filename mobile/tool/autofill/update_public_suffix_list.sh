#!/usr/bin/env bash
# Refreshes the Public Suffix List AutoFill uses to tell which part of a host a site owns
# (assets/data/public_suffix_list.dat, read by lib/core/public_suffixes.dart): a login saved on
# accounts.example.com fills on mail.example.com, and one saved on alice.herokuapp.com doesn't
# fill on bob.herokuapp.com. Run it from mobile/ before each release, and commit the file if it
# changed:
#
#   tool/autofill/update_public_suffix_list.sh
#
# The file is kept byte for byte as publicsuffix.org serves it (MPL 2.0, its licence in its
# header). A download that isn't the list, or is missing its ICANN or private section, is
# refused and leaves the bundled file alone.
set -euo pipefail

url="https://publicsuffix.org/list/public_suffix_list.dat"
mobile="$(cd "$(dirname "$0")/../.." && pwd)"
target="$mobile/assets/data/public_suffix_list.dat"
download="$(mktemp)"
trap 'rm -f "$download"' EXIT

curl --fail --silent --show-error --max-time 60 --proto '=https' --output "$download" "$url"

for marker in "===BEGIN ICANN DOMAINS===" "===END ICANN DOMAINS===" "===BEGIN PRIVATE DOMAINS===" "===END PRIVATE DOMAINS==="; do
  grep -qF "$marker" "$download" || { echo "Not the Public Suffix List: no $marker" >&2; exit 1; }
done
for rule in "com" "co.uk" "herokuapp.com" "github.io"; do
  grep -qx "$rule" "$download" || { echo "The list has no rule $rule" >&2; exit 1; }
done
echo "$(grep -cv '^\(//\|$\)' "$download") rules"

if cmp -s "$download" "$target"; then
  echo "Unchanged: ${target#"$mobile"/}"
else
  cp "$download" "$target"
  echo "Updated: ${target#"$mobile"/}"
fi
