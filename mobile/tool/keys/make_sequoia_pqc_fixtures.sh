#!/bin/sh
# Makes the post-quantum Sequoia fixtures of test/fixtures/keys/sequoia/pqc
# with sq 1.5.0 in the image of tool/keys/docker/sq-1.5.0.Dockerfile. Run
# once on 2026-11-17, from mobile/; never rerun over the files:
#
#   docker run --rm -v "$PWD/test/fixtures/keys:/fixtures" -v "$PWD/tool/keys:/tool:ro" \
#     kemlock-sq:1.5.0 sh /tool/make_sequoia_pqc_fixtures.sh /fixtures/sequoia/pqc
set -eu
OUT=$1
mkdir -p "$(dirname "$OUT")"
mkdir "$OUT"
cd "$OUT"
HOME=$(mktemp -d)
export HOME
# --overwrite only lets the output go to /dev/null
SQ="sq --batch --overwrite --home=$HOME/sq"
sq version > versions.txt 2>&1
printf 'fixture passphrase' > "$HOME/pass"
printf 'A message for a post-quantum key.\nIts second line.\n' > message.txt

# A version 6 key: ML-DSA-65+Ed25519 to certify and, in a subkey, sign;
# ML-KEM-768+X25519 to encrypt
$SQ key generate --own-key --without-password --cipher-suite mldsa65-ed25519 --profile rfc9580 \
  --userid 'Fixture Sequoia <sq@example.org>' --can-sign --cannot-authenticate --can-encrypt universal \
  --expiration never --output standard.secret.asc --rev-cert "$HOME/rev.asc"
$SQ key delete --cert-file standard.secret.asc --output standard.public.asc
$SQ key password --cert-file standard.secret.asc --new-password-file "$HOME/pass" --output standard-protected.secret.asc
for f in standard.secret.asc standard.public.asc standard-protected.secret.asc; do
  $SQ inspect "$f" > "${f%.asc}.inspect.txt" 2>&1
  $SQ packet dump "$f" > "${f%.asc}.packets.txt" 2>&1
done

# A message encrypted to it and signed by it; and the three signatures
$SQ encrypt --for-file standard.public.asc --signer-file standard.secret.asc --output message.pgp message.txt
$SQ decrypt --recipient-file standard.secret.asc --signer-file standard.public.asc --dump-session-key \
  --output /dev/null message.pgp > message.decrypt.txt 2>&1
$SQ sign --signer-file standard.secret.asc --signature-file message.txt.sig message.txt
$SQ sign --signer-file standard.secret.asc --message --output message.signed.pgp message.txt
$SQ sign --signer-file standard.secret.asc --cleartext --output message.cleartext.asc message.txt
for f in message.pgp message.txt.sig message.signed.pgp message.cleartext.asc; do
  $SQ packet dump "$f" > "$f.packets.txt" 2>&1
done
$SQ verify --signer-file standard.public.asc --signature-file message.txt.sig message.txt > verify.txt 2>&1
$SQ verify --signer-file standard.public.asc --message --output /dev/null message.signed.pgp >> verify.txt 2>&1
$SQ verify --signer-file standard.public.asc --cleartext --output /dev/null message.cleartext.asc >> verify.txt 2>&1
rm -rf "$HOME"
