#!/bin/sh
# Checks the post-quantum keys Kemlock changed (tasks 9.1 and 9.2 of
# add-post-quantum-pgp), as tool/keys/write_pq_edited_keys.dart writes
# them. Run from mobile/:
#
#   dart run tool/keys/write_pq_edited_keys.dart <keys>
#
# then, in the image of tool/keys/docker/sq-1.5.0.Dockerfile, for the
# standard key's changes and the ML-KEM-768+X25519 subkey:
#
#   docker run --rm -v "$PWD/tool/keys:/tool:ro" -v "<keys>:/keys:ro" -e KEYS=/keys \
#     kemlock-sq:1.5.0 sh /tool/pq_edit_check.sh
#
# and in the image of tool/keys/docker/gnupg-2.5.24.Dockerfile, for the
# Kyber subkey:
#
#   docker run --rm -v "$PWD/tool/keys:/tool:ro" -v "<keys>:/keys:ro" -e KEYS=/keys \
#     kemlock-gnupg:2.5.24 sh /tool/pq_edit_check.sh
#
# With sq, each changed standard key must inspect without a warning and
# lint clean, show its change (the new expiry, the user ID, the subkey, the
# revocation), and the revocation certificate made here must revoke the
# original key; a message to each new encryption subkey must decrypt with
# the secret key, and a file signed with the new signing subkey verify.
# With GnuPG, the Ed25519 key with its new Kyber subkey must import with
# no error, its signatures be good, and a message GnuPG encrypts to it go
# to the Kyber subkey and decrypt with the key's passphrase.

set -eu

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
HOME=$WORK
export HOME
echo "a message" > "$WORK/message"

if command -v sq > /dev/null 2>&1; then
  SQ="sq --batch --overwrite --home=$WORK/sq"
  sq version 2>&1 | head -1
  for name in standard.expiry standard.uid standard.encrypt standard.sign standard.revoked ed25519.pq-standard; do
    echo "== $name"
    $SQ inspect "$KEYS/$name.public.asc" > "$WORK/inspect" 2>&1 || fail "$name: inspect: $(cat "$WORK/inspect")"
    cat "$WORK/inspect"
    if grep -qi 'invalid\|error\|warning' "$WORK/inspect"; then fail "$name: sq inspect warned"; fi
    $SQ cert lint --cert-file "$KEYS/$name.public.asc" > "$WORK/lint" 2>&1 || fail "$name: lint: $(cat "$WORK/lint")"
    cat "$WORK/lint"
    case $name in
      standard.expiry) grep -q 'Expiration time:' "$WORK/inspect" || fail "no expiry" ;;
      standard.uid) grep -q 'UserID: Ada Added <added@example.org>' "$WORK/inspect" || fail "no new user ID" ;;
      standard.revoked) grep -q 'Revoked' "$WORK/inspect" || fail "not revoked" ;;
      standard.sign) [ "$(grep -c 'Public-key algo: ML-DSA-65+Ed25519' "$WORK/inspect")" = 2 ] || fail "no ML-DSA-65+Ed25519 subkey" ;;
      standard.encrypt) [ "$(grep -c 'Public-key algo: ML-KEM-768+X25519' "$WORK/inspect")" = 2 ] || fail "no second ML-KEM-768+X25519 subkey" ;;
      ed25519.pq-standard) grep -q 'Public-key algo: ML-KEM-768+X25519' "$WORK/inspect" || fail "no ML-KEM-768+X25519 subkey" ;;
    esac
  done

  echo "== the revocation certificate over the original key"
  cat "$KEYS/standard.original.public.asc" "$KEYS/standard.rev.asc" > "$WORK/revoked.asc"
  $SQ inspect "$WORK/revoked.asc" > "$WORK/inspect" 2>&1 || fail "inspect: $(cat "$WORK/inspect")"
  cat "$WORK/inspect"
  grep -q 'Revoked' "$WORK/inspect" || fail "the certificate does not revoke the key"

  for name in standard.encrypt ed25519.pq-standard; do
    echo "== $name: a message to it"
    $SQ encrypt --for-file "$KEYS/$name.public.asc" --without-signature --output "$WORK/$name.pgp" "$WORK/message" 2> "$WORK/stderr" || fail "$name: encrypt: $(cat "$WORK/stderr")"
    $SQ packet dump "$WORK/$name.pgp" | grep -i 'PKESK\|algo' | head -6
    $SQ decrypt --recipient-file "$KEYS/$name.secret.asc" --output "$WORK/$name.out" "$WORK/$name.pgp" 2> "$WORK/stderr" || fail "$name: decrypt: $(cat "$WORK/stderr")"
    cat "$WORK/stderr"
    [ "$(cat "$WORK/message")" = "$(cat "$WORK/$name.out")" ] || fail "$name: decrypted message differs"
  done

  echo "== standard.sign: a file signed with the key, which now has two keys that sign"
  $SQ sign --signer-file "$KEYS/standard.sign.secret.asc" --signature-file "$WORK/message.sig" "$WORK/message" 2> "$WORK/stderr" || fail "sign: $(cat "$WORK/stderr")"
  $SQ packet dump "$WORK/message.sig" | grep -i 'issuer\|algo' | head -4
  $SQ verify --signer-file "$KEYS/standard.sign.public.asc" --signature-file "$WORK/message.sig" "$WORK/message" > "$WORK/verify" 2>&1 || fail "verify: $(cat "$WORK/verify")"
  cat "$WORK/verify"
  grep -q 'Authenticated signature made by' "$WORK/verify" || fail "signature not good"
  echo "PASS: sq took every change of the standard key and both new subkeys"
fi

# GnuPG 2.5 or later: the 2.4 some images carry reads no Kyber key
if command -v gpg > /dev/null 2>&1 && gpg --version | head -1 | grep -q " 2.[5-9]"; then
  gpg --version | head -1
  home="$WORK/gnupg"
  mkdir -m 700 "$home"
  g() { gpg --homedir "$home" --batch --no-tty --pinentry-mode loopback "$@"; }
  echo "== ed25519.pq-gnupg"
  g --status-fd 1 --passphrase 'fixture passphrase' --import "$KEYS/ed25519.pq-gnupg.secret.asc" > "$WORK/status" 2> "$WORK/stderr" || fail "import: $(cat "$WORK/stderr")"
  cat "$WORK/stderr"
  if grep -q '^\[GNUPG:\] \(ERROR\|FAILURE\|IMPORT_PROBLEM\)' "$WORK/status"; then fail "import: $(cat "$WORK/status")"; fi
  g --with-colons --check-signatures > "$WORK/sigs" 2>&1 || fail "check-signatures: $(cat "$WORK/sigs")"
  if grep -q '^sig:[^!]' "$WORK/sigs"; then fail "a signature is not good: $(cat "$WORK/sigs")"; fi
  g --list-secret-keys --with-subkey-fingerprints 2>&1 | grep -v "^$home" | grep -v '^-*$'
  kyber=$(g --with-colons --list-keys --with-subkey-fingerprints | awk -F: '/^sub/ && $4 == 8 {s=1; next} s && /^fpr/ {print $10; exit}')
  [ -n "$kyber" ] || fail "GnuPG lists no Kyber subkey"
  g --trust-model always --recipient "$kyber!" --output "$WORK/message.gpg" --encrypt "$WORK/message" 2> "$WORK/stderr" || fail "encrypt: $(cat "$WORK/stderr")"
  g --list-packets "$WORK/message.gpg" 2> /dev/null | grep '^:' || true
  gpgconf --homedir "$home" --kill gpg-agent
  g --status-fd 1 --passphrase 'fixture passphrase' --output "$WORK/message.out" --decrypt "$WORK/message.gpg" > "$WORK/status" 2> "$WORK/stderr" || fail "decrypt: $(cat "$WORK/stderr")"
  cat "$WORK/stderr"
  grep -q "^\[GNUPG:\] DECRYPTION_KEY $kyber " "$WORK/status" || fail "not decrypted with the Kyber subkey"
  [ "$(cat "$WORK/message")" = "$(cat "$WORK/message.out")" ] || fail "decrypted message differs"
  echo "PASS: GnuPG took the Kyber subkey, encrypted to it and decrypted with it"
fi
