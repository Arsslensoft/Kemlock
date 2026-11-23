#!/bin/sh
# Checks that OpenSSH accepts the SSH signatures Kemlock makes (task 2.4 of
# the add-ssh-signatures change). tool/keys/write_sshsigs.dart signs
# test/fixtures/keys/openssh/sshsig/hello.txt for the namespace `file` with
# each of the Ed25519, ECDSA P-256, ECDSA P-384 and RSA fixture keys, and
# for each signature this:
#
#   - runs `ssh-keygen -Y check-novalidate -n file`, which checks the
#     signature against the key inside it;
#   - runs `ssh-keygen -Y verify` with an allowed-signers file that names
#     the key's `.pub` line, which also checks who signed;
#   - runs both again over a changed file, which must fail.
#
# The test suite cannot do this: it needs ssh-keygen. Run it by hand from
# mobile/ (needs ssh-keygen and the Flutter SDK's dart):
#
#   tool/keys/sshsig_check.sh [work directory]
#
# The work directory defaults to a new one under $TMPDIR and is deleted at
# the end.

set -eu

KEYS=test/fixtures/keys/openssh
MESSAGE=$KEYS/sshsig/hello.txt
SIGNER=signer@example.org
WORK=${1:-$(mktemp -d "${TMPDIR:-/tmp}/kemlock-sshsig-check.XXXXXX")}
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ssh -V 2>&1
dart run tool/keys/write_sshsigs.dart "$WORK/signatures" "$MESSAGE" file
printf 'hellp' > "$WORK/changed.txt"

for key in ed25519 ecdsa256 ecdsa384 rsa3072; do
  echo "== $key"
  sig="$WORK/signatures/$key.sig"
  printf '%s %s\n' "$SIGNER" "$(tr -d '\r' < "$KEYS/$key.pub" | cut -d' ' -f1,2)" > "$WORK/allowed_signers"

  ssh-keygen -Y check-novalidate -n file -s "$sig" < "$MESSAGE" > "$WORK/out" 2>&1 || fail "check-novalidate: $(cat "$WORK/out")"
  grep -q '^Good "file" signature' "$WORK/out" || fail "check-novalidate said: $(cat "$WORK/out")"
  echo "check-novalidate: $(cat "$WORK/out")"

  ssh-keygen -Y verify -f "$WORK/allowed_signers" -I "$SIGNER" -n file -s "$sig" < "$MESSAGE" > "$WORK/out" 2>&1 || fail "verify: $(cat "$WORK/out")"
  grep -q "^Good \"file\" signature for $SIGNER" "$WORK/out" || fail "verify said: $(cat "$WORK/out")"
  echo "verify: $(cat "$WORK/out")"

  if ssh-keygen -Y check-novalidate -n file -s "$sig" < "$WORK/changed.txt" > "$WORK/out" 2>&1; then fail "a changed file was accepted"; fi
  if ssh-keygen -Y verify -f "$WORK/allowed_signers" -I "$SIGNER" -n git -s "$sig" < "$MESSAGE" > "$WORK/out" 2>&1; then fail "another namespace was accepted"; fi
  echo "a changed file and another namespace: refused"
done
echo "PASS: OpenSSH accepted the signature of each key"
