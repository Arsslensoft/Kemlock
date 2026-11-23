#!/usr/bin/env bash
# Refreshes the password rules of known sites the Android autofill service follows when it
# suggests a strong password (android/app/src/main/assets/password-manager-resources, read by
# com.kemlock.app.passwords.SiteRules): a site that takes 16 characters at most gets 16. Run it
# from mobile/ before each release, and commit the files if they changed:
#
#   tool/autofill/update_password_rules.sh
#
# Both files are kept byte for byte as Apple's password-manager-resources serves them (MIT, the
# licence beside the rules). A download that isn't the rules list, or is missing sites it has
# always named, is refused and leaves the bundled files alone. iOS needs no copy: it hands the
# extension a site's rules itself.
set -euo pipefail

base="https://raw.githubusercontent.com/apple/password-manager-resources/main"
mobile="$(cd "$(dirname "$0")/../.." && pwd)"
target="$mobile/android/app/src/main/assets/password-manager-resources"
rules="$(mktemp)"
licence="$(mktemp)"
trap 'rm -f "$rules" "$licence"' EXIT

curl --fail --silent --show-error --max-time 60 --proto '=https' --output "$rules" "$base/quirks/password-rules.json"
curl --fail --silent --show-error --max-time 60 --proto '=https' --output "$licence" "$base/LICENSE.md"

for site in '"163.com"' '"apple.com"' '"password-rules"'; do
  grep -qF "$site" "$rules" || { echo "Not the password rules list: no $site" >&2; exit 1; }
done
grep -qF "Permission is hereby granted, free of charge" "$licence" || { echo "Not the MIT licence" >&2; exit 1; }
echo "$(grep -c '"password-rules"' "$rules") sites"

for pair in "$rules:password-rules.json" "$licence:LICENSE.md"; do
  file="${pair%%:*}"
  name="${pair#*:}"
  if cmp -s "$file" "$target/$name"; then
    echo "Unchanged: ${target#"$mobile"/}/$name"
  else
    cp "$file" "$target/$name"
    echo "Updated: ${target#"$mobile"/}/$name"
  fi
done
