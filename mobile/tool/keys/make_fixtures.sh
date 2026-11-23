#!/bin/sh
# Made the key files in test/fixtures/keys/{openssl,openssh,gnupg} once, on
# 2026-11-15, with OpenSSL 3.6.1, OpenSSH 10.2 and GnuPG 2.5.24. The keys are
# random, so running this again makes different files: the committed ones are
# never regenerated, and this script is kept as the exact record of how they
# were made. It refuses to write into a directory that exists.
#
#   tool/keys/make_fixtures.sh <new directory>
#
# OPENSSL must be OpenSSL 3.5 or later (macOS's LibreSSL has no ML-KEM).

set -eu

OUT=${1:?usage: make_fixtures.sh <new directory>}
OPENSSL=${OPENSSL:-/opt/homebrew/opt/openssl@3/bin/openssl}
PASS='fixture passphrase'

if [ -e "$OUT" ]; then
  echo "$OUT exists; the fixtures are never regenerated" >&2
  exit 1
fi
mkdir -p "$OUT/openssl" "$OUT/openssh" "$OUT/gnupg"

# ─── OpenSSL: PKCS#8, PKCS#1, SEC1, SPKI ──────────────────────────────────────
cd "$OUT/openssl"
O=$OPENSSL
$O version > versions.txt

$O genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out rsa2048.pkcs8.pem
$O ecparam -name prime256v1 -genkey -out p256.sec1-with-params.pem
$O pkey -in p256.sec1-with-params.pem -out p256.pkcs8.pem
$O genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out p384.pkcs8.pem
$O genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-521 -out p521.pkcs8.pem
$O genpkey -algorithm ED25519 -out ed25519.pkcs8.pem
$O genpkey -algorithm X25519 -out x25519.pkcs8.pem
$O genpkey -algorithm ED448 -out ed448.pkcs8.pem

for k in rsa2048 p256 p384 p521 ed25519 x25519 ed448; do
  $O pkey -in $k.pkcs8.pem -outform DER -out $k.pkcs8.der
  $O pkey -in $k.pkcs8.pem -pubout -out $k.spki.pem
  $O pkey -in $k.pkcs8.pem -pubout -outform DER -out $k.spki.der
done
for k in rsa2048 p256 p384 p521; do
  $O pkey -in $k.pkcs8.pem -traditional -out $k.traditional.pem
  $O pkey -in $k.pkcs8.pem -traditional -outform DER -out $k.traditional.der
done

$O req -new -x509 -key p256.pkcs8.pem -subj /CN=fixture -days 3650 -out p256.cert.pem
$O rsa -in rsa2048.pkcs8.pem -aes128 -traditional -passout "pass:$PASS" -out rsa2048.legacy-aes128.pem

# ─── OpenSSL: PBES2-encrypted PKCS#8 ──────────────────────────────────────────
$O pkcs8 -topk8 -in rsa2048.pkcs8.pem -v2 aes-128-cbc -v2prf hmacWithSHA1 -passout "pass:$PASS" -out rsa2048.pbes2-sha1-aes128.pem
$O pkcs8 -topk8 -in p256.pkcs8.pem -v2 aes-256-cbc -v2prf hmacWithSHA256 -passout "pass:$PASS" -out p256.pbes2-sha256-aes256.pem
$O pkcs8 -topk8 -in ed25519.pkcs8.pem -v2 aes-256-cbc -v2prf hmacWithSHA512 -passout "pass:$PASS" -out ed25519.pbes2-sha512-aes256.pem
$O pkcs8 -topk8 -in x25519.pkcs8.pem -v2 aes-128-cbc -v2prf hmacWithSHA256 -passout "pass:$PASS" -out x25519.pbes2-sha256-aes128.pem
$O pkcs8 -topk8 -in p384.pkcs8.pem -v2 aes-256-cbc -passout "pass:$PASS" -outform DER -out p384.pbes2-default.der
$O pkcs8 -topk8 -in p256.pkcs8.pem -v2 aes-192-cbc -v2prf hmacWithSHA256 -iter 100000 -passout "pass:$PASS" -out p256.pbes2-sha256-aes192-100000.pem
$O pkcs8 -topk8 -in p256.pkcs8.pem -scrypt -passout "pass:$PASS" -out p256.pbes2-scrypt.pem
$O pkcs8 -topk8 -in p256.pkcs8.pem -v2 des3 -passout "pass:$PASS" -out p256.pbes2-des3.pem
$O pkcs8 -topk8 -in rsa2048.pkcs8.pem -v1 PBE-SHA1-3DES -passout "pass:$PASS" -out rsa2048.pbes1-sha1-3des.pem
for f in *.pbes*.pem; do
  echo "== $f" >> encrypted-asn1.txt
  $O asn1parse -in "$f" | head -14 >> encrypted-asn1.txt
done

# ─── OpenSSL: ML-KEM and ML-DSA in each PKCS#8 form ───────────────────────────
# Seed-only, expanded-only ("priv-only") and both ("seed-priv", OpenSSL's
# default). The seeds are kept, so a test can make the same keys.
$O rand -hex 64 > ml-kem-768.seed.hex
$O rand -hex 64 > ml-kem-1024.seed.hex
$O rand -hex 32 > ml-dsa-65.seed.hex
$O rand -hex 64 > ml-kem-512.seed.hex
for alg in ml-kem-768 ml-kem-1024 ml-dsa-65; do
  ALG=$(echo $alg | tr a-z A-Z)
  case $alg in ml-kem*) formats=ml-kem.output_formats ;; *) formats=ml-dsa.output_formats ;; esac
  $O genpkey -algorithm "$ALG" -pkeyopt hexseed:"$(cat $alg.seed.hex)" -out $alg.both.pem
  $O pkey -in $alg.both.pem -provparam $formats=seed-only -out $alg.seed.pem
  $O pkey -in $alg.both.pem -provparam $formats=priv-only -out $alg.expanded.pem
  $O pkey -in $alg.both.pem -outform DER -out $alg.both.der
  $O pkey -in $alg.both.pem -pubout -out $alg.spki.pem
  $O pkey -in $alg.both.pem -pubout -outform DER -out $alg.spki.der
done
$O genpkey -algorithm ML-KEM-512 -pkeyopt hexseed:"$(cat ml-kem-512.seed.hex)" -out ml-kem-512.both.pem

for f in *.pkcs8.pem *.traditional.pem ml-*.pem; do
  echo "== $f" >> pkey-text.txt
  $O pkey -in "$f" -noout -text 2>&1 | head -3 >> pkey-text.txt
done

# ─── OpenSSH ──────────────────────────────────────────────────────────────────
cd "$OUT/openssh"
ssh -V > versions.txt 2>&1
ssh-keygen -q -t ed25519 -N '' -C 'fixture ed25519' -f ed25519
ssh-keygen -q -t ed25519 -N "$PASS" -C 'fixture ed25519 protected' -f ed25519.protected
ssh-keygen -q -t ecdsa -b 256 -N '' -C 'fixture ecdsa p256' -f ecdsa256
ssh-keygen -q -t ecdsa -b 256 -N "$PASS" -C 'fixture ecdsa p256 protected' -f ecdsa256.protected
ssh-keygen -q -t ecdsa -b 384 -N '' -C 'fixture ecdsa p384' -f ecdsa384
ssh-keygen -q -t ecdsa -b 384 -N "$PASS" -C 'fixture ecdsa p384 protected' -f ecdsa384.protected
ssh-keygen -q -t ecdsa -b 521 -N '' -C 'fixture ecdsa p521' -f ecdsa521
ssh-keygen -q -t rsa -b 3072 -N '' -C 'fixture rsa 3072' -f rsa3072
ssh-keygen -q -t rsa -b 3072 -N "$PASS" -C 'fixture rsa 3072 protected' -f rsa3072.protected
for c in aes128-ctr aes192-ctr aes128-cbc aes192-cbc aes256-cbc chacha20-poly1305@openssh.com aes256-gcm@openssh.com; do
  ssh-keygen -q -t ed25519 -N "$PASS" -Z $c -C "fixture ed25519 $c" -f ed25519.$c
done
ssh-keygen -q -t ed25519 -N "$PASS" -a 4 -C 'fixture ed25519 4 rounds' -f ed25519.rounds4
ssh-keygen -q -t ed25519 -N '' -C 'fixture ca' -f ca
ssh-keygen -q -s ca -I fixture -n fixture ed25519.pub
rm ca ca.pub
for f in *.pub; do ssh-keygen -l -f "$f" >> fingerprints.txt; done
ssh-keygen -y -P "$PASS" -f ed25519.protected > ed25519.protected.y.txt

# ─── GnuPG ────────────────────────────────────────────────────────────────────
cd "$OUT/gnupg"
GNUPGHOME=$(mktemp -d)
export GNUPGHOME
gpg --version | head -2 > versions.txt
q() { gpg --batch --pinentry-mode loopback "$@"; }
make_key() { # name email algo subalgo passphrase expiry subexpiry file
  q --passphrase "$5" --quick-generate-key "$1 <$2>" "$3" cert,sign "$6"
  fpr=$(gpg --list-keys --with-colons "$2" | awk -F: '/^fpr/ {print $10; exit}')
  q --passphrase "$5" --quick-add-key "$fpr" "$4" encr "$7"
  q --passphrase "$5" --armor --export-secret-keys "$fpr" > "$8.secret.asc"
  q --passphrase "$5" --export-secret-keys "$fpr" > "$8.secret.gpg"
  gpg --armor --export "$fpr" > "$8.public.asc"
  gpg --export "$fpr" > "$8.public.gpg"
  gpg --list-keys --with-subkey-fingerprints "$fpr" | sed "s|$GNUPGHOME|<GNUPGHOME>|" > "$8.list.txt"
  gpg --list-keys --with-subkey-fingerprints --with-colons "$fpr" > "$8.colons.txt"
}
make_key 'Fixture Ed25519' ed25519@example.org ed25519 cv25519 '' 0 2y ed25519
make_key 'Fixture Ed25519 Protected' ed25519p@example.org ed25519 cv25519 "$PASS" 5y 0 ed25519-protected
make_key 'Fixture RSA' rsa@example.org rsa3072 rsa3072 '' 0 0 rsa3072
make_key 'Fixture RSA Protected' rsap@example.org rsa3072 rsa3072 "$PASS" 0 3y rsa3072-protected
# A second user ID on the first key.
fpr=$(gpg --list-keys --with-colons ed25519@example.org | awk -F: '/^fpr/ {print $10; exit}')
q --passphrase '' --quick-add-uid "$fpr" 'Fixture Second <second@example.org>'
q --passphrase '' --armor --export-secret-keys "$fpr" > ed25519-two-uids.secret.asc
gpg --list-keys --with-subkey-fingerprints "$fpr" | sed "s|$GNUPGHOME|<GNUPGHOME>|" > ed25519-two-uids.list.txt
gpg --list-keys --with-subkey-fingerprints --with-colons "$fpr" > ed25519-two-uids.colons.txt
gpgconf --kill gpg-agent
rm -rf "$GNUPGHOME"
