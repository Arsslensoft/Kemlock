#!/usr/bin/env bash
# Refreshes the passkey provider's list of trusted browsers: Google's list of the browsers
# Credential Manager hands a website's origin to, which the Android app bundles as
# android/app/src/main/res/raw/passkey_browsers.json and reads in CallerCheck
# (android/app/src/main/kotlin/com/kemlock/app/passkeys/Callers.kt). Run it from mobile/
# before each release, and commit the file if it changed:
#
#   tool/passkeys/update_trusted_browsers.sh
#
# The file is kept byte for byte as Google serves it, so running this again on an unchanged list
# reproduces it. A download that isn't the list androidx's CallingAppInfo.getOrigin reads is
# refused and leaves the bundled file alone.
set -euo pipefail

url="https://www.gstatic.com/gpm-passkeys-privileged-apps/apps.json"
mobile="$(cd "$(dirname "$0")/../.." && pwd)"
target="$mobile/android/app/src/main/res/raw/passkey_browsers.json"
download="$(mktemp)"
trap 'rm -f "$download"' EXIT

curl --fail --silent --show-error --max-time 60 --proto '=https' --output "$download" "$url"

python3 -I - "$download" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    apps = json.load(f)["apps"]
# androidx compares fingerprints as it writes them: upper-case hex pairs joined by colons
fingerprint = re.compile(r"^(?:[0-9A-F]{2}:){31}[0-9A-F]{2}$")
android = [app for app in apps if app.get("type") == "android"]
if not android:
    sys.exit("No Android apps in the list")
for app in android:
    name = app["info"].get("package_name")
    if not name:
        sys.exit("An app without a package name")
    signatures = app["info"]["signatures"]
    if not signatures:
        sys.exit(f"{name} has no certificate")
    for signature in signatures:
        if not fingerprint.match(signature["cert_fingerprint_sha256"]):
            sys.exit(f"{name} has a fingerprint androidx wouldn't match")
if "com.android.chrome" not in {app["info"]["package_name"] for app in android}:
    sys.exit("Chrome isn't on the list")
print(f"{len(android)} browsers")
PY

if cmp -s "$download" "$target"; then
  echo "Unchanged: ${target#"$mobile"/}"
else
  cp "$download" "$target"
  echo "Updated: ${target#"$mobile"/}"
fi
