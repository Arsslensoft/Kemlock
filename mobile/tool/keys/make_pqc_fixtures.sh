#!/bin/sh
# Makes the post-quantum GnuPG fixtures of test/fixtures/keys/gnupg/pqc
# with GnuPG 2.5.24 in the image of tool/keys/docker/gnupg-2.5.24.Dockerfile.
# Run once on 2026-11-17, from mobile/; never rerun over the files:
#
#   docker run --rm -v "$PWD/test/fixtures/keys:/fixtures" -v "$PWD/tool/keys:/tool:ro" \
#     kemlock-gnupg:2.5.24 sh /tool/make_pqc_fixtures.sh /fixtures/gnupg/pqc
#
# GnuPG cannot change the passphrase of a Kyber key ("Invalid
# S-expression"), so a protected key is a key of its own, made with its
# passphrase, not a twin of an unprotected one.
set -eu
OUT=$1
mkdir "$OUT"
cd "$OUT"
PASS='fixture passphrase'
GNUPGHOME=$(mktemp -d)
export GNUPGHOME
gpg --version | head -2 > versions.txt
q() { gpg --batch --pinentry-mode loopback "$@"; }
fpr_of() { gpg --list-keys --with-colons "$1" | awk -F: '/^fpr/ {print $10; exit}'; }
printf 'A message for a post-quantum key.\nIts second line.\n' > message.txt

# name uid primary-algo sub-algo passphrase
make_key() {
  if [ "$3" = pqc ]; then
    q --passphrase "$5" --quick-generate-key "$2" pqc default 0
  else
    q --passphrase "$5" --quick-generate-key "$2" "$3" cert,sign 0
    q --passphrase "$5" --quick-add-key "$(fpr_of "$2")" "$4" encr 0
  fi
  fpr=$(fpr_of "$2")
  q --passphrase "$5" --armor --export-secret-keys "$fpr" > "$1.secret.asc"
  gpg --armor --export "$fpr" > "$1.public.asc"
  gpg --list-keys --with-subkey-fingerprints "$fpr" | sed "s|$GNUPGHOME|<GNUPGHOME>|" > "$1.list.txt"
  gpg --list-keys --with-subkey-fingerprints --with-colons "$fpr" > "$1.colons.txt"
  gpg --list-packets "$1.public.asc" > "$1.public.packets.txt"
  gpg --list-packets "$1.secret.asc" > "$1.secret.packets.txt"
  q --trust-model always --encrypt --recipient "$fpr" --output "$1.message.gpg" message.txt
}
make_key ky768-cv25519 'Fixture Kyber <ky768@example.org>' ed25519 ky768_cv25519 ''
make_key ky768-cv25519-protected 'Fixture Kyber Protected <ky768p@example.org>' ed25519 ky768_cv25519 "$PASS"
make_key pqc 'Fixture PQC Shortcut <pqc@example.org>' pqc - ''
make_key pqc-protected 'Fixture PQC Shortcut Protected <pqcp@example.org>' pqc - "$PASS"
make_key ky1024-bp384 'Fixture Kyber 1024 <ky1024@example.org>' ed25519 ky1024_bp384 ''
make_key ky1024-bp384-protected 'Fixture Kyber 1024 Protected <ky1024p@example.org>' ed25519 ky1024_bp384 "$PASS"

# To the first key: with --force-ocb, and with Kemlock's Ed25519 key, which
# does not advertise AEAD, beside it, which gives SEIPD version 1
ky=$(fpr_of ky768@example.org)
q --trust-model always --force-ocb --encrypt --recipient "$ky" --output ky768-cv25519.force-ocb.gpg message.txt
gpg --import /fixtures/kemlock/pgp-ed25519.public.asc
kemlock=$(gpg --with-colons --import-options show-only --import /fixtures/kemlock/pgp-ed25519.public.asc | awk -F: '/^fpr/ {print $10; exit}')
q --trust-model always --encrypt --recipient "$ky" --recipient "$kemlock" --output ky768-cv25519.seipd1.gpg message.txt

# What each encrypted file is, and its session key
: > packets.txt
: > session-keys.txt
for f in *.gpg; do
  { echo "== $f"; gpg --list-packets "$f" 2>&1 | sed "s|$GNUPGHOME|<GNUPGHOME>|"; } >> packets.txt
  key=$(q --passphrase "$PASS" --show-session-key --output /dev/null --decrypt "$f" 2>&1 | sed -n "s/^gpg: session key: '\(.*\)'$/\1/p")
  echo "$f $key" >> session-keys.txt
done
gpgconf --kill gpg-agent
rm -rf "$GNUPGHOME"
