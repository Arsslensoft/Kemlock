#!/bin/sh
# Checks that GnuPG accepts every message and signature Kemlock writes
# (tasks 8.2 and 13.2 of the add-pgp-messages change). It imports the
# fixture keys into a throwaway GNUPGHOME, then, for each file that
# test/fixtures/pgp/kemlock/manifest.txt lists:
#
#   - a message: `gpg --decrypt` must report DECRYPTION_OKAY, give back the
#     plain file byte for byte, and report GOODSIG from each signer listed;
#   - a clear-signed text or a detached signature: `gpg --verify` must
#     report GOODSIG from the signer, and for a clear-signed text the text
#     gpg extracts must be the plain file's;
#
# and in every case gpg's stderr must hold no WARNING and its status no
# BADSIG, ERRSIG or failure. The files are what the writers give for fixed
# randomness: test/crypto/pgp/encrypt_test.dart fails when the writers stop
# giving those bytes, so what GnuPG accepts here is what the app writes.
#
# Run it from mobile/ (needs gpg 2.4 or later):
#
#   tool/pgp/gnupg_check.sh [work directory]
#
# The work directory defaults to a new one under $TMPDIR and is deleted at
# the end. GnuPG's sockets must fit in about 100 characters, so keep its
# path short.

set -eu

PASS='fixture passphrase'
FIXTURES=$(pwd)/test/fixtures
SAMPLES=$FIXTURES/pgp/kemlock
WORK=${1:-$(mktemp -d "${TMPDIR:-/tmp}/kemlock-pgp.XXXXXX")}
mkdir -p "$WORK"
HOME_DIR="$WORK/home"
cleanup() {
  [ -d "$HOME_DIR" ] && gpgconf --homedir "$HOME_DIR" --kill gpg-agent 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

gpg --version | head -1
mkdir "$HOME_DIR"
chmod 700 "$HOME_DIR" 2> /dev/null || true
g() { gpg --homedir "$HOME_DIR" --batch --no-tty --pinentry-mode loopback "$@"; }

for key in keys/gnupg/ed25519.secret.asc keys/gnupg/rsa3072.secret.asc keys/kemlock/pgp-ed25519.unprotected.asc keys/kemlock/pgp-rsa4096.unprotected.asc; do
  g --import "$FIXTURES/$key" 2> "$WORK/stderr" || fail "import $key: $(cat "$WORK/stderr")"
done
# The keys are the person's own: without that, gpg warns that a good
# signature comes from a key nobody vouches for, which says nothing of
# the signature.
g --list-keys --with-colons | awk -F: '/^pub/ {primary = 1} /^fpr/ && primary {print $10 ":6:"; primary = 0}' | g --import-ownertrust 2> /dev/null

# The status and stderr of the last gpg run, checked for anything amiss.
clean() {
  if grep -q 'WARNING' "$WORK/stderr"; then fail "$1: gpg warned: $(grep WARNING "$WORK/stderr")"; fi
  if grep -q '^\[GNUPG:\] \(BADSIG\|ERRSIG\|ERROR\|FAILURE\|DECRYPTION_FAILED\|NODATA\|BADMDC\)' "$WORK/status"; then
    fail "$1: gpg reported: $(grep '^\[GNUPG:\]' "$WORK/status")"
  fi
}
# Every signer of the comma-separated list must have a VALIDSIG line that
# ends with their primary key's fingerprint.
signers() {
  [ "$2" = "-" ] && {
    if grep -q '^\[GNUPG:\] GOODSIG' "$WORK/status"; then fail "$1: a signature nobody expected"; fi
    return 0
  }
  for fpr in $(echo "$2" | tr ',' ' '); do
    grep -q "^\[GNUPG:\] VALIDSIG .* $fpr\$" "$WORK/status" || fail "$1: no valid signature by $fpr"
  done
  grep -q '^\[GNUPG:\] GOODSIG' "$WORK/status" || fail "$1: no GOODSIG"
}

count=0
while read -r file kind plain signed; do
  [ -n "$file" ] || continue
  rm -f "$WORK/out"
  case $kind in
    toKeys | toPassphrase)
      g --passphrase "$PASS" --status-fd 3 --output "$WORK/out" --decrypt "$SAMPLES/$file" 3> "$WORK/status" 2> "$WORK/stderr" \
        || fail "$file: gpg --decrypt: $(cat "$WORK/stderr")"
      grep -q '^\[GNUPG:\] DECRYPTION_OKAY' "$WORK/status" || fail "$file: no DECRYPTION_OKAY"
      grep -q '^\[GNUPG:\] GOODMDC' "$WORK/status" || fail "$file: no GOODMDC"
      cmp -s "$WORK/out" "$FIXTURES/pgp/gnupg/$plain" || fail "$file: the plain text differs"
      ;;
    clearSigned)
      g --status-fd 3 --verify "$SAMPLES/$file" 3> "$WORK/status" 2> "$WORK/stderr" \
        || fail "$file: gpg --verify: $(cat "$WORK/stderr")"
      rm -f "$WORK/out"
      g --output "$WORK/out" --decrypt "$SAMPLES/$file" 2> /dev/null || fail "$file: gpg could not extract the text"
      # gpg gives the text back without the trailing spaces and tabs of its
      # lines, which a clear-text signature does not cover
      sed 's/[ 	]*$//' "$FIXTURES/pgp/gnupg/$plain" > "$WORK/expected"
      cmp -s "$WORK/out" "$WORK/expected" || fail "$file: the text gpg extracts differs"
      ;;
    detached)
      g --status-fd 3 --verify "$SAMPLES/$file" "$FIXTURES/pgp/gnupg/$plain" 3> "$WORK/status" 2> "$WORK/stderr" \
        || fail "$file: gpg --verify: $(cat "$WORK/stderr")"
      ;;
    *) fail "$file: unknown kind $kind" ;;
  esac
  clean "$file"
  signers "$file" "$signed"
  echo "ok  $file"
  count=$((count + 1))
done < "$SAMPLES/manifest.txt"

[ "$count" -gt 0 ] || fail "no samples in $SAMPLES/manifest.txt"
echo "PASS: GnuPG decrypted and verified all $count files Kemlock wrote, with no warning"
