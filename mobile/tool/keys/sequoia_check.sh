#!/bin/sh
# Checks that Sequoia accepts the standard post-quantum PGP key Kemlock
# generates (task 4.6 of add-post-quantum-pgp): RFC 9980's version 6 key,
# ML-DSA-65+Ed25519 with an ML-KEM-768+X25519 subkey, made by
# tool/keys/write_pgp_keys.dart. With sq 1.5.0 or later it:
#
#   - inspects the public key and lints it, failing on any error;
#   - lists it, which must show the user ID, a primary key that signs and
#     an ML-KEM-768+X25519 subkey that encrypts;
#   - encrypts a message to the public key and decrypts it with the secret
#     key exported with a passphrase;
#   - signs a message with that secret key and verifies the signature
#     with the public key.
#
# Run it in the image of tool/keys/docker/sq-1.5.0.Dockerfile, with the
# keys written first on this side, from mobile/:
#
#   dart run tool/keys/write_pgp_keys.dart <keys> 'sequoia check passphrase'
#   docker run --rm -v "$PWD/tool/keys:/tool:ro" -v "<keys>:/keys:ro" -e KEYS=/keys \
#     kemlock-sq:1.5.0 sh /tool/sequoia_check.sh

set -eu

PASS=${PASS:-'sequoia check passphrase'}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

HOME=$WORK
export HOME
SQ="sq --batch --overwrite --home=$WORK/sq"
printf '%s' "$PASS" > "$WORK/pass"
KEY=$KEYS/pq-standard
sq version 2>&1 | head -3

echo "== inspect"
$SQ inspect "$KEY.public.asc" > "$WORK/inspect" 2>&1 || fail "inspect: $(cat "$WORK/inspect")"
cat "$WORK/inspect"
grep -q 'Public-key algo: ML-DSA-65+Ed25519' "$WORK/inspect" || fail "the primary key is not ML-DSA-65+Ed25519"
grep -q 'Key flags: certification, signing' "$WORK/inspect" || fail "the primary key does not sign"
grep -q 'Public-key algo: ML-KEM-768+X25519' "$WORK/inspect" || fail "no ML-KEM-768+X25519 subkey"
grep -q 'Key flags: transport encryption, data-at-rest encryption' "$WORK/inspect" || fail "the subkey does not encrypt"
grep -q 'UserID: Ada Lovelace <pq-standard@example.org>' "$WORK/inspect" || fail "user ID not listed"
if grep -qi 'invalid\|error\|warning' "$WORK/inspect"; then fail "sq inspect warned"; fi

echo "== lint"
$SQ cert lint --cert-file "$KEY.public.asc" > "$WORK/lint" 2>&1 || fail "lint: $(cat "$WORK/lint")"
cat "$WORK/lint"

echo "== encrypt and decrypt"
echo "a message for pq-standard" > "$WORK/message"
$SQ encrypt --for-file "$KEY.public.asc" --without-signature --output "$WORK/message.pgp" "$WORK/message" 2> "$WORK/stderr" || fail "encrypt: $(cat "$WORK/stderr")"
$SQ packet dump "$WORK/message.pgp" | grep -i 'packet\|version\|algo' | head -8
$SQ decrypt --recipient-file "$KEY.secret.asc" --password-file "$WORK/pass" --output "$WORK/message.out" "$WORK/message.pgp" 2> "$WORK/stderr" || fail "decrypt: $(cat "$WORK/stderr")"
cat "$WORK/stderr"
[ "$(cat "$WORK/message")" = "$(cat "$WORK/message.out")" ] || fail "decrypted message differs"
echo "encrypt and decrypt: ok"

echo "== sign and verify"
$SQ sign --signer-file "$KEY.secret.asc" --password-file "$WORK/pass" --signature-file "$WORK/message.sig" "$WORK/message" 2> "$WORK/stderr" || fail "sign: $(cat "$WORK/stderr")"
$SQ verify --signer-file "$KEY.public.asc" --signature-file "$WORK/message.sig" "$WORK/message" > "$WORK/verify" 2>&1 || fail "verify: $(cat "$WORK/verify")"
cat "$WORK/verify"
grep -q 'Authenticated signature made by' "$WORK/verify" || fail "signature not good"
echo "sign and verify: ok"
echo "PASS: sq read, checked and used the standard key"

# What Kemlock wrote to and with the standard key, when
# tool/keys/write_pq_messages.dart wrote it beside the keys
if [ -d "$KEYS/messages" ]; then
  M=$KEYS/messages
  echo "== Kemlock's messages"
  for file in to-standard.asc to-all.gpg; do
    # to-all.gpg is not signed, so no signer is asked for
    signer=""
    [ "$file" = to-standard.asc ] && signer="--signer-file=$KEY.public.asc"
    $SQ decrypt --recipient-file "$KEY.secret.asc" --password-file "$WORK/pass" $signer \
      --output "$WORK/$file.out" "$M/$file" 2> "$WORK/stderr" || fail "$file: $(cat "$WORK/stderr")"
    cat "$WORK/stderr"
    [ "$(cat "$M/message.txt")" = "$(cat "$WORK/$file.out")" ] || fail "$file decrypted differs"
    echo "$file: decrypted"
  done
  $SQ decrypt --recipient-file "$KEY.secret.asc" --password-file "$WORK/pass" --signer-file "$KEY.public.asc" \
    --output /dev/null "$M/to-standard.asc" > "$WORK/verify" 2>&1 || fail "to-standard: $(cat "$WORK/verify")"
  grep -q 'Authenticated signature made by' "$WORK/verify" || fail "to-standard: the signature inside is not good"
  echo "to-standard.asc: the signature inside is good"
  $SQ verify --signer-file "$KEY.public.asc" --signature-file "$M/standard.sig" "$M/message.txt" > "$WORK/verify" 2>&1 || fail "standard.sig: $(cat "$WORK/verify")"
  cat "$WORK/verify"
  grep -q 'Authenticated signature made by' "$WORK/verify" || fail "standard.sig is not good"
  $SQ verify --signer-file "$KEY.public.asc" --cleartext --output /dev/null "$M/standard.clear.asc" > "$WORK/verify" 2>&1 || fail "standard.clear.asc: $(cat "$WORK/verify")"
  cat "$WORK/verify"
  grep -q 'Authenticated signature made by' "$WORK/verify" || fail "standard.clear.asc is not good"
  echo "PASS: sq opened and verified what Kemlock wrote"
fi
