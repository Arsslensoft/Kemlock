#!/usr/bin/env bash
# Signs the free build's unsigned release APKs with Kemlock's release key, on
# the owner's machine and never on a build machine (openspec:
# add-fdroid-release, design decision 8). The signed file is the built file
# with a signature added and nothing else changed.
#
#   tool/release/sign.sh <keystore> <key alias> <dir with the unsigned APKs>
#
# Each kemlock-<version>-<abi>-unsigned.apk gives kemlock-<version>-<abi>.apk
# beside it, and SHA256SUMS lists every file of the release. It uses apksigner
# from build-tools 34 and refuses any other: F-Droid checks a release by
# copying its signature onto its own build, and cannot copy a signature that
# apksigner 35 or later made. Set APKSIGNER to its path if it is not in
# $ANDROID_HOME/build-tools/34.0.0. It asks for the keystore's password once, unless
# KEMLOCK_KEYSTORE_PASSWORD holds it, and hands it to apksigner through that variable.
set -euo pipefail

[ $# -eq 3 ] || { echo "usage: $0 <keystore> <key alias> <dir with the unsigned APKs>" >&2; exit 2; }
keystore="$1"
alias="$2"
dir="$3"
tools="${ANDROID_HOME:-$HOME/Android/Sdk}/build-tools/34.0.0"
apksigner="${APKSIGNER:-$tools/apksigner}"
zipalign="${ZIPALIGN:-$tools/zipalign}"

# apksigner's own --version says 0.9 in every build-tools; the build-tools it
# came with say which it is.
version="$(sed -n 's/^Pkg.Revision=//p' "$(dirname "$apksigner")/source.properties" 2>/dev/null || true)"
case "$version" in
  34.*) ;;
  *) echo "sign.sh: apksigner of build-tools ${version:-unknown}; F-Droid can copy only a signature made by build-tools 34's" >&2; exit 1 ;;
esac

if [ -z "${KEMLOCK_KEYSTORE_PASSWORD:-}" ]; then
  read -rs -p "Keystore password: " KEMLOCK_KEYSTORE_PASSWORD
  echo
fi
export KEMLOCK_KEYSTORE_PASSWORD

shopt -s nullglob
unsigned=("$dir"/kemlock-*-unsigned.apk)
[ ${#unsigned[@]} -gt 0 ] || { echo "sign.sh: no kemlock-*-unsigned.apk in $dir" >&2; exit 1; }

for apk in "${unsigned[@]}"; do
  signed="${apk%-unsigned.apk}.apk"
  # The build aligns its APKs; signing must not change a byte of what it built.
  "$zipalign" -c -p 4 "$apk"
  "$apksigner" sign --ks "$keystore" --ks-key-alias "$alias" --ks-pass env:KEMLOCK_KEYSTORE_PASSWORD \
    --v4-signing-enabled false --in "$apk" --out "$signed"
  "$apksigner" verify --print-certs "$signed" | grep -i 'SHA-256'
done

(cd "$dir" && sha256sum kemlock-*.apk > SHA256SUMS && cat SHA256SUMS)
