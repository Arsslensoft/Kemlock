#!/bin/sh
# Made the messages and signatures in test/fixtures/pgp/gnupg once, on
# 2026-11-16, with the GnuPG 2.4.9 of Git for Windows. Session keys, salts
# and signing times are random or of the day, so running this again makes
# different files: the committed ones are never regenerated, and this
# script is kept as the exact record of how they were made. It refuses to
# write into a directory that exists.
#
#   tool/pgp/make_fixtures.sh <new directory>      (from mobile/)
#
# The keys of test/fixtures/keys/gnupg and test/fixtures/keys/kemlock are
# imported into a throwaway GNUPGHOME, never regenerated. Four keys are new
# and are written beside the messages: one with a signing subkey, an RSA
# 1024 key, a NIST P-256 key, and the Ed25519 fixture key exported with
# `--export-secret-subkeys`, whose primary key is a stub with no secret.
#
# Every form is forced by an option, so no file depends on a build's
# defaults; `default-to-ed25519.gpg` and `sym-default.gpg` alone are made
# with none, to record what this build chose.

set -eu

OUT=${1:?usage: make_fixtures.sh <new directory>}
PASS='fixture passphrase'
KEYS=$(pwd)/test/fixtures/keys

if [ -e "$OUT" ]; then
  echo "$OUT exists; the fixtures are never regenerated" >&2
  exit 1
fi
mkdir -p "$OUT"
dart run tool/pgp/sample_file.dart "$OUT/large.bin" 5242880
cd "$OUT"

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
gpg --version | head -2 > versions.txt
q() { gpg --batch --no-tty --pinentry-mode loopback --trust-model always "$@"; }

for k in gnupg/ed25519 gnupg/rsa3072 gnupg/ed25519-protected gnupg/rsa3072-protected kemlock/pgp-ed25519.unprotected kemlock/pgp-rsa4096.unprotected; do
  case $k in kemlock/*) f=$KEYS/$k.asc ;; *) f=$KEYS/$k.secret.asc ;; esac
  q --passphrase "$PASS" --import "$f"
done

ED=1FCDA135EE42400EC2B77CE677249ABE661CF8DB
RSA=EA29C79D1C6570277907BB485D49D28C8EFC2F98
EDP=1BB5EC3961E61EE44F919AB63FCD57EBA0308CA9
RSAP=40563A0693F24839F76000FE6D181E7A2C932FEA
fpr_of() { gpg --show-keys --with-colons "$1" | awk -F: '/^fpr/ {print $10; exit}'; }
KED=$(fpr_of "$KEYS/kemlock/pgp-ed25519.public.asc")
KRSA=$(fpr_of "$KEYS/kemlock/pgp-rsa4096.public.asc")

# ─── The plain inputs ─────────────────────────────────────────────────────────
# A text with what clear-signing has to get right: a line starting with a
# dash, one starting with "From ", trailing spaces and a trailing tab, and
# text outside ASCII.
printf 'A message for the fixtures.\n- a line that starts with a dash\nFrom a line that starts with From\ntrailing spaces   \n\ta tab, then a trailing tab\t\n\nCl\303\251, na\303\257ve, \346\227\245\346\234\254.\n' > message.txt
# 200 KB that compresses well, for the compressed forms.
i=0
while [ $i -lt 4000 ]; do
  printf 'line %05d of a file that compresses well: 0123456789\n' $i
  i=$((i + 1))
done > report.txt

# ─── New keys ─────────────────────────────────────────────────────────────────
# A certify-only primary key with a signing subkey and an encryption subkey.
q --passphrase '' --quick-generate-key 'Fixture Signing Subkey <subsign@example.org>' ed25519 cert 0
SUB=$(gpg --list-keys --with-colons subsign@example.org | awk -F: '/^fpr/ {print $10; exit}')
q --passphrase '' --quick-add-key "$SUB" ed25519 sign 0
q --passphrase '' --quick-add-key "$SUB" cv25519 encr 0
# RSA 1024: old keys still verify and decrypt, and are refused for new work.
q --passphrase '' --quick-generate-key 'Fixture RSA 1024 <rsa1024@example.org>' rsa1024 cert,sign 0
R1024=$(gpg --list-keys --with-colons rsa1024@example.org | awk -F: '/^fpr/ {print $10; exit}')
q --passphrase '' --quick-add-key "$R1024" rsa1024 encr 0
# NIST P-256, a curve Kemlock names and does not use.
q --passphrase '' --quick-generate-key 'Fixture NIST P-256 <nistp256@example.org>' nistp256 cert,sign 0
P256=$(gpg --list-keys --with-colons nistp256@example.org | awk -F: '/^fpr/ {print $10; exit}')
q --passphrase '' --quick-add-key "$P256" nistp256 encr 0
for pair in "$SUB signing-subkey" "$R1024 rsa1024" "$P256 nistp256"; do
  set -- $pair
  q --passphrase '' --armor --export-secret-keys "$1" > "$2.secret.asc"
  gpg --armor --export "$1" > "$2.public.asc"
  gpg --list-keys --with-subkey-fingerprints --with-colons "$1" > "$2.colons.txt"
done
# The Ed25519 fixture key as a card or an offline primary key leaves it:
# the primary key's secret replaced by a GnuPG stub (S2K 101).
q --passphrase '' --export-secret-subkeys "$ED" > ed25519.stub.secret.gpg

# ─── Encrypted to keys ────────────────────────────────────────────────────────
enc() {
  out=$1
  shift
  q --output "$out" "$@" --encrypt message.txt
}
enc default-to-ed25519.gpg -r $ED
enc to-ed25519.seipd.gpg --rfc4880 -r $ED
enc to-ed25519.ocb.gpg --force-ocb -r $ED
enc to-rsa3072.seipd.gpg --rfc4880 -r $RSA
enc to-rsa3072.ocb.gpg --force-ocb -r $RSA
enc to-two.gpg --rfc4880 -r $ED -r $RSA
enc hidden.gpg --rfc4880 --throw-keyids -r $ED
enc to-kemlock-ed25519.gpg -r $KED
enc to-kemlock-rsa4096.gpg -r $KRSA
enc to-protected-ed25519.gpg --rfc4880 -r $EDP
enc to-protected-rsa3072.gpg --rfc4880 -r $RSAP
enc to-signing-subkey.gpg --rfc4880 -r $SUB
enc to-rsa1024.gpg --rfc4880 -r $R1024
enc to-nistp256.gpg --rfc4880 -r $P256
enc aes128.gpg --rfc4880 --cipher-algo AES -r $ED
enc aes192.gpg --rfc4880 --cipher-algo AES192 -r $ED
enc armored.asc --rfc4880 --armor -r $ED
enc armored-headers.asc --rfc4880 --armor --emit-version --comment 'a comment header' -r $ED

# ─── Compression, on a file that compresses ───────────────────────────────────
for z in zip zlib bzip2; do
  q --output $z.gpg --rfc4880 --compress-algo $z -r $ED --encrypt report.txt
done
q --output uncompressed.gpg --rfc4880 --compress-algo none -r $ED --encrypt report.txt
# A file made by `gpg --sign --encrypt` with BZip2, in GnuPG's OCB form.
q --output signed-bzip2.ocb.gpg --force-ocb --compress-algo bzip2 -u $RSA -r $ED --sign --encrypt report.txt

# ─── 5 MB from a pipe: partial body lengths all the way down ──────────────────
q --output large.gpg --rfc4880 --compress-algo none -r $ED --encrypt < large.bin
# 1 MB in sixteen OCB chunks of 64 KiB (GnuPG's own default is one of 4 MiB).
head -c 1048576 large.bin | q --output chunks.ocb.gpg --force-ocb --chunk-size 16 --compress-algo none -r $ED --encrypt

# ─── Signed and encrypted, and several signers ────────────────────────────────
q --output signed-encrypted.gpg --rfc4880 -u $ED -r $ED --sign --encrypt message.txt
q --output signed-encrypted-rsa.gpg --rfc4880 -u $RSA -r $RSA --sign --encrypt message.txt
q --output two-signers-encrypted.gpg --rfc4880 -u $ED -u $RSA -r $ED --sign --encrypt message.txt
q --output two-signers.gpg -u $ED -u $RSA --sign message.txt
q --output inline-signed.gpg -u $ED --sign message.txt
q --output inline-signed.asc --armor -u $ED --sign message.txt

# ─── With a passphrase ────────────────────────────────────────────────────────
sym() {
  out=$1
  shift
  q --passphrase "$PASS" --output "$out" "$@" --symmetric message.txt
}
sym sym-default.gpg
sym sym-ocb.gpg --force-ocb
sym sym-s2k0.gpg --rfc4880 --s2k-mode 0 --s2k-cipher-algo AES256 --cipher-algo AES256
sym sym-s2k1.gpg --rfc4880 --s2k-mode 1 --s2k-cipher-algo AES256 --cipher-algo AES256
for h in SHA1 SHA224 SHA256 SHA384 SHA512; do
  sym sym-s2k3-$h.gpg --rfc4880 --s2k-mode 3 --s2k-digest-algo $h --s2k-cipher-algo AES256
done
sym sym-aes128.gpg --rfc4880 --s2k-cipher-algo AES --cipher-algo AES
q --passphrase "$PASS" --output sym-and-key.gpg --rfc4880 --s2k-cipher-algo AES256 -r $ED --symmetric --encrypt message.txt

# ─── Signatures ───────────────────────────────────────────────────────────────
q --output clearsigned.asc -u $ED --clearsign message.txt
q --output clearsigned-rsa.asc -u $RSA --clearsign message.txt
for pair in "$ED ed25519" "$RSA rsa3072" "$EDP ed25519-protected" "$RSAP rsa3072-protected"; do
  set -- $pair
  q --passphrase "$PASS" --output message.txt.$2.sig -u $1 --detach-sign message.txt
  q --passphrase "$PASS" --output message.txt.$2.asc --armor -u $1 --detach-sign message.txt
done
q --output report.txt.sig -u $ED --detach-sign report.txt
# By the signing subkey, with a signature expiry (subpacket 3, critical).
q --output message.txt.signing-subkey.sig --default-sig-expire 10y -u $SUB --detach-sign message.txt
# In text mode (signature type 0x01) over a file.
q --output message.txt.text.sig --textmode -u $ED --detach-sign message.txt
q --output message.txt.rsa1024.sig -u $R1024 --detach-sign message.txt
q --output message.txt.nistp256.sig -u $P256 --detach-sign message.txt
q --output message.txt.sha1.sig --digest-algo SHA1 --allow-weak-digest-algos -u $RSA --detach-sign message.txt

# ─── What Kemlock refuses by name ─────────────────────────────────────────────
q --output cast5.gpg --rfc4880 --cipher-algo CAST5 --allow-old-cipher-algos -r $ED --encrypt message.txt || echo "cast5.gpg: not made by this build" >&2
q --passphrase "$PASS" --output sym-cast5.gpg --rfc4880 --cipher-algo CAST5 --s2k-cipher-algo CAST5 --allow-old-cipher-algos --symmetric message.txt || echo "sym-cast5.gpg: not made by this build" >&2
# The old form with no integrity protection (tag 9), which GnuPG 2.4 no
# longer writes: hand-built from the passphrase packet of sym-aes128.gpg
# (its first 15 bytes) and a tag 9 packet of 40 random bytes. A reader must
# refuse it at the tag.
head -c 15 sym-aes128.gpg > no-mdc.gpg
printf '\311\050' >> no-mdc.gpg
head -c 40 /dev/urandom >> no-mdc.gpg

# ─── The records the tests read ───────────────────────────────────────────────
# Session keys, as `gpg --show-session-key` prints them: <cipher id>:<hex>.
for f in *.gpg armored.asc armored-headers.asc; do
  case $f in two-signers.gpg | inline-signed.gpg | ed25519.stub.secret.gpg | no-mdc.gpg) continue ;; esac
  key=$(q --passphrase "$PASS" --show-session-key --decrypt "$f" 2>&1 >/dev/null | sed -n "s/^gpg: session key: '\(.*\)'.*/\1/p")
  echo "$f $key" >> session-keys.txt
done
# What each signature is: gpg's VALIDSIG status line (the signing key's
# fingerprint, the date and time it was made, and the primary key's
# fingerprint last).
status() { grep -a '^\[GNUPG:\] \(VALIDSIG\|ERRSIG\)' | sed "s/^\[GNUPG:\] /$1 /"; }
for f in message.txt.*.sig message.txt.*.asc; do
  q --status-fd 1 --verify "$f" message.txt 2>/dev/null | status "$f" >> signatures.txt || true
done
q --status-fd 1 --verify report.txt.sig report.txt 2>/dev/null | status report.txt.sig >> signatures.txt
for f in clearsigned.asc clearsigned-rsa.asc inline-signed.gpg inline-signed.asc two-signers.gpg signed-encrypted.gpg signed-encrypted-rsa.gpg two-signers-encrypted.gpg signed-bzip2.ocb.gpg; do
  q --status-fd 1 --output - --decrypt "$f" 2>/dev/null | status "$f" >> signatures.txt || true
done
# Which packets each file holds.
for f in *.gpg *.asc *.sig; do
  case $f in *.secret.asc | *.public.asc | ed25519.stub.secret.gpg) continue ;; esac
  echo "== $f" >> packets.txt
  q --passphrase "$PASS" --list-packets "$f" 2>/dev/null | grep -a '^:\|version\|algo\|S2K\|salt\|keyid' | sed 's/^/  /' >> packets.txt || true
done

rm large.bin
gpgconf --kill gpg-agent
rm -rf "$GNUPGHOME"
