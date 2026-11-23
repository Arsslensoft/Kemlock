#!/bin/sh
# Checks that GnuPG accepts the PGP keys Kemlock generates (task 4.9 of the
# add-vault-items change, and 4.6 of add-post-quantum-pgp). For an Ed25519,
# an RSA 4096 and a GnuPG-format post-quantum key (Ed25519 with a Kyber-768
# with X25519 subkey) made by tool/keys/write_pgp_keys.dart, each in a
# throwaway GNUPGHOME, it:
#
#   - imports the public key, then the secret key exported with a
#     passphrase, and fails on any error gpg reports;
#   - checks every signature (`gpg --check-signatures`) is good;
#   - lists the key, which must show the user ID and an encryption subkey;
#   - encrypts a message to the key and decrypts it with the passphrase,
#     and signs one and verifies it, so the secret parts work too; for the
#     post-quantum key, the subkey must be listed as ky768_cv25519 and the
#     message's session key must be encrypted with algorithm 8.
#
# It then shows what GnuPG makes of the standard post-quantum key (RFC
# 9980's version 6 key), without and with --allow-9980.
#
# Run it from mobile/ (needs gpg 2.5 or later and the Flutter SDK's dart):
#
#   tool/keys/gnupg_check.sh [work directory]
#
# or, with GnuPG in the image of tool/keys/docker/gnupg-2.5.24.Dockerfile
# and the keys written first on this side:
#
#   dart run tool/keys/write_pgp_keys.dart <keys> 'gnupg check passphrase'
#   docker run --rm -v "$PWD/tool/keys:/tool:ro" -v "<keys>:/keys:ro" -e KEYS=/keys \
#     kemlock-gnupg:2.5.24 sh /tool/gnupg_check.sh
#
# The work directory defaults to a new one under $TMPDIR and is deleted at
# the end. GnuPG's sockets must fit in about 100 characters, so keep its
# path short.

set -eu

PASS='gnupg check passphrase'
WORK=${1:-$(mktemp -d "${TMPDIR:-/tmp}/kemlock-gpg.XXXXXX")}
mkdir -p "$WORK"
cleanup() {
  for home in "$WORK"/home-*; do
    [ -d "$home" ] && gpgconf --homedir "$home" --kill gpg-agent 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

gpg --version | head -1
if [ -n "${KEYS:-}" ]; then
  cp -r "$KEYS" "$WORK/keys"
else
  dart run tool/keys/write_pgp_keys.dart "$WORK/keys" "$PASS"
fi

for type in ed25519 rsa4096 pq-gnupg; do
  echo "== $type"
  home="$WORK/home-$type"
  mkdir "$home" && { chmod 700 "$home" 2>/dev/null || true; }
  g() { gpg --homedir "$home" --batch --no-tty --pinentry-mode loopback "$@"; }

  # Import: gpg exits non-zero on an error; its status lines say what it did.
  g --status-fd 1 --import "$WORK/keys/$type.public.asc" > "$WORK/status" 2> "$WORK/stderr" || fail "public import: $(cat "$WORK/stderr")"
  grep -q '^\[GNUPG:\] IMPORT_OK' "$WORK/status" || fail "public key not imported"
  g --status-fd 1 --passphrase "$PASS" --import "$WORK/keys/$type.secret.asc" > "$WORK/status" 2> "$WORK/stderr" || fail "secret import: $(cat "$WORK/stderr")"
  grep -q '^\[GNUPG:\] IMPORT_OK' "$WORK/status" || fail "secret key not imported"
  if grep -q '^\[GNUPG:\] \(ERROR\|FAILURE\|IMPORT_PROBLEM\)' "$WORK/status"; then fail "gpg reported: $(grep ERROR "$WORK/status")"; fi
  cat "$WORK/stderr"

  # Every signature good: `sig:!` in the colon listing, never `-` or `%`.
  g --with-colons --check-signatures "$type@example.org" > "$WORK/sigs" 2>&1 || fail "check-signatures: $(cat "$WORK/sigs")"
  grep -q '^sig:!' "$WORK/sigs" || fail "no good signature"
  if grep -q '^sig:[^!]' "$WORK/sigs"; then fail "a signature is not good: $(grep '^sig:[^!]' "$WORK/sigs")"; fi
  echo "signatures: $(grep -c '^sig:!' "$WORK/sigs") good"

  g --list-secret-keys --with-subkey-fingerprints "$type@example.org" | grep -v "^$home" | grep -v '^-*$'
  g --list-keys --with-colons "$type@example.org" > "$WORK/list"
  grep -q "^uid:.*:Ada Lovelace <$type@example.org>:" "$WORK/list" || fail "user ID not listed"
  grep -q '^sub:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:e:' "$WORK/list" || fail "no encryption subkey"
  if [ "$type" = pq-gnupg ]; then
    grep -q '^sub:[^:]*:768:8:.*:e:.*:ky768_cv25519:' "$WORK/list" || fail "the subkey is not a ky768_cv25519 key that encrypts"
  fi

  echo "a message for $type" > "$WORK/$type.message"
  g --trust-model always --recipient "$type@example.org" --output "$WORK/$type.message.gpg" --encrypt "$WORK/$type.message" 2> "$WORK/stderr" || fail "encrypt: $(cat "$WORK/stderr")"
  if [ "$type" = pq-gnupg ]; then
    g --list-packets "$WORK/$type.message.gpg" 2> /dev/null | grep '^:' > "$WORK/packets" || true
    cat "$WORK/packets"
    grep -q '^:pubkey enc packet: version 3, algo 8,' "$WORK/packets" || fail "the session key is not encrypted with algorithm 8"
  fi
  # The passphrase is asked for again, not taken from the import
  gpgconf --homedir "$home" --kill gpg-agent
  g --passphrase "$PASS" --output "$WORK/$type.message.out" --decrypt "$WORK/$type.message.gpg" 2> "$WORK/stderr" || fail "decrypt: $(cat "$WORK/stderr")"
  cmp -s "$WORK/$type.message" "$WORK/$type.message.out" || fail "decrypted message differs"
  echo "encrypt and decrypt: ok"
  g --passphrase "$PASS" --local-user "$type@example.org" --output "$WORK/$type.message.sig" --detach-sign "$WORK/$type.message" 2> "$WORK/stderr" || fail "sign: $(cat "$WORK/stderr")"
  g --status-fd 1 --verify "$WORK/$type.message.sig" "$WORK/$type.message" > "$WORK/status" 2> "$WORK/stderr" || fail "verify: $(cat "$WORK/stderr")"
  grep -q '^\[GNUPG:\] GOODSIG' "$WORK/status" || fail "signature not good"
  echo "sign and verify: ok"
done
echo "PASS: GnuPG imported, checked and used the three keys"

# RFC 9980's standard key, which GnuPG 2.5 reads only when told to
for allow in '' --allow-9980; do
  echo "== pq-standard ${allow:-(by default)}"
  home="$WORK/home-standard$allow"
  mkdir -m 700 "$home"
  g() { gpg --homedir "$home" --batch --no-tty --pinentry-mode loopback $allow "$@"; }
  g --import "$WORK/keys/pq-standard.public.asc" 2>&1 || true
  g --passphrase "$PASS" --import "$WORK/keys/pq-standard.secret.asc" 2>&1 || true
  g --with-colons --check-signatures pq-standard@example.org 2>&1 | grep '^\(pub\|sub\|sig\|uid\)' || true
  g --list-keys --with-subkey-fingerprints pq-standard@example.org 2>&1 | grep -v "^$home" | grep -v '^-*$' || true
  echo "a message for pq-standard" > "$WORK/standard.message"
  if g --trust-model always --recipient pq-standard@example.org --output "$WORK/standard$allow.gpg" --encrypt "$WORK/standard.message" 2>&1; then
    g --list-packets "$WORK/standard$allow.gpg" 2> /dev/null | grep '^:' || true
    gpgconf --homedir "$home" --kill gpg-agent
    g --passphrase "$PASS" --decrypt "$WORK/standard$allow.gpg" 2>&1 || true
  fi
done

# What Kemlock wrote to and with the GnuPG-format key, when
# tool/keys/write_pq_messages.dart wrote it beside the keys
if [ -d "$WORK/keys/messages" ]; then
  M="$WORK/keys/messages"
  home="$WORK/home-pq-gnupg"
  g() { gpg --homedir "$home" --batch --no-tty --pinentry-mode loopback "$@"; }
  echo "== Kemlock's messages"
  gpgconf --homedir "$home" --kill gpg-agent
  g --status-fd 1 --trust-model always --passphrase "$PASS" --output "$WORK/to-gnupg.out" --decrypt "$M/to-gnupg.gpg" > "$WORK/status" 2> "$WORK/stderr" || fail "to-gnupg: $(cat "$WORK/stderr")"
  cat "$WORK/stderr"
  cmp -s "$M/message.txt" "$WORK/to-gnupg.out" || fail "to-gnupg decrypted differs"
  grep -q '^\[GNUPG:\] GOODSIG' "$WORK/status" || fail "to-gnupg: the signature inside is not good"
  echo "to-gnupg.gpg: decrypted, signature good"
  for who in pq-gnupg rsa4096; do
    home="$WORK/home-$who"
    gpgconf --homedir "$home" --kill gpg-agent
    g() { gpg --homedir "$home" --batch --no-tty --pinentry-mode loopback "$@"; }
    g --passphrase "$PASS" --output "$WORK/to-all.$who.out" --decrypt "$M/to-all.gpg" 2> "$WORK/stderr" || fail "to-all with $who: $(cat "$WORK/stderr")"
    cat "$WORK/stderr"
    cmp -s "$M/message.txt" "$WORK/to-all.$who.out" || fail "to-all decrypted with $who differs"
    echo "to-all.gpg: decrypted with $who"
  done
  g --list-packets "$M/to-all.gpg" 2> /dev/null | grep '^:' || true
  home="$WORK/home-pq-gnupg"
  g() { gpg --homedir "$home" --batch --no-tty --pinentry-mode loopback "$@"; }
  g --status-fd 1 --trust-model always --verify "$M/gnupg.sig" "$M/message.txt" > "$WORK/status" 2> "$WORK/stderr" || fail "gnupg.sig: $(cat "$WORK/stderr")"
  cat "$WORK/stderr"
  grep -q '^\[GNUPG:\] GOODSIG' "$WORK/status" || fail "gnupg.sig is not good"
  echo "gnupg.sig: good"
  echo "PASS: GnuPG opened and verified what Kemlock wrote"
fi


# ─── Changed keys (openspec: add-pgp-key-editing, task 3.6) ─────────────────
#
# tool/keys/write_edited_keys.dart makes each kind of change, one at a time,
# to the keys of test/fixtures/keys/gnupg/editing and other/editing. Each
# result is imported alone into a fresh GNUPGHOME, which must take it with
# no error and no warning (a signing subkey without its cross-certification
# warns), and every signature must be good. Its listing, with the reason of
# a revocation, is printed. Each revocation certificate Kemlock made is
# imported over the key's original public key, which it must revoke. The
# protected key's new subkeys must open with the key's own passphrase: a
# message to the new encryption subkey decrypts, and the new signing
# subkey signs. test/fixtures/keys/gnupg/editing/gnupg-check.txt is one
# run's output.

dart run tool/keys/write_edited_keys.dart "$WORK/edited"
n=0
fresh() {
  n=$((n + 1))
  home="$WORK/home-e$n"
  mkdir "$home" && { chmod 700 "$home" 2>/dev/null || true; }
}
g() { gpg --homedir "$home" --batch --no-tty --pinentry-mode loopback "$@"; }
imp() {
  g --status-fd 1 "$@" > "$WORK/status" 2> "$WORK/stderr" || fail "import $*: $(cat "$WORK/stderr")"
  if grep -q '^\[GNUPG:\] \(ERROR\|FAILURE\|IMPORT_PROBLEM\)' "$WORK/status"; then fail "$*: $(cat "$WORK/status")"; fi
  if grep -qi 'warning\|cross-cert' "$WORK/stderr"; then fail "$*: $(cat "$WORK/stderr")"; fi
}
show() {
  g --with-colons --check-signatures > "$WORK/sigs" 2>&1 || fail "check-signatures: $(cat "$WORK/sigs")"
  if grep -q '^\(sig\|rev\):[^!]' "$WORK/sigs"; then fail "a signature is not good: $(grep '^\(sig\|rev\):[^!]' "$WORK/sigs")"; fi
  echo "signatures: $(grep -c '^\(sig\|rev\):!' "$WORK/sigs") good"
  g --list-options show-sig-subpackets=29 --check-signatures 2>/dev/null | grep -v "^$home" | grep -v '^-*$'
  g --with-colons --list-keys | grep '^\(pub\|sub\|uid\)'
}

for key in signing-subkey rsa3072-expiring protected direct-key; do
  for file in "$WORK/edited/$key".*.public.asc; do
    change=${file#"$WORK/edited/$key."}
    change=${change%.public.asc}
    [ "$change" = original ] && continue
    echo "== $key, $change"
    fresh
    imp --import "$file"
    show
    case $change in
      revoked) grep -q '^pub:r:' "$WORK/sigs" || fail "$key not revoked" ;;
      uid) g --with-colons --list-keys | grep -m 1 '^uid' | grep -q 'Fixture Added' || fail "$key: the new user ID is not first" ;;
    esac
  done
  echo "== $key, its revocation certificate over the original public key"
  fresh
  imp --import "$WORK/edited/$key.original.public.asc"
  imp --import "$WORK/edited/$key.rev.asc"
  show
  grep -q '^pub:r:' "$WORK/sigs" || fail "$key not revoked by its certificate"
done

echo "== protected: the new subkeys open with the key's passphrase"
for change in encrypt sign; do
  fresh
  imp --passphrase 'fixture passphrase' --import "$WORK/edited/protected.$change.secret.asc"
  newest=$(g --with-colons --list-keys --with-subkey-fingerprints | awk -F: '/^sub/ {s=1; next} s && /^fpr/ {f=$10; s=0} END {print f}')
  echo "a message" > "$WORK/message"
  if [ $change = encrypt ]; then
    g --trust-model always --recipient protected@example.org --status-fd 1 --output "$WORK/message.gpg" --encrypt "$WORK/message" > "$WORK/status" 2>&1 || fail "encrypt: $(cat "$WORK/status")"
    g --passphrase 'fixture passphrase' --status-fd 1 --output "$WORK/message.out" --decrypt "$WORK/message.gpg" > "$WORK/status" 2>&1 || fail "decrypt: $(cat "$WORK/status")"
    grep -q "^\[GNUPG:\] DECRYPTION_KEY $newest " "$WORK/status" || fail "not decrypted with the new subkey"
    cmp -s "$WORK/message" "$WORK/message.out" || fail "decrypted message differs"
    echo "decrypted with the new subkey $newest"
  else
    g --passphrase 'fixture passphrase' --local-user protected@example.org --output "$WORK/message.sig" --detach-sign "$WORK/message" 2> "$WORK/stderr" || fail "sign: $(cat "$WORK/stderr")"
    g --status-fd 1 --verify "$WORK/message.sig" "$WORK/message" > "$WORK/status" 2>&1 || fail "verify: $(cat "$WORK/status")"
    grep -q "^\[GNUPG:\] VALIDSIG $newest " "$WORK/status" || fail "not signed by the new subkey"
    echo "signed by the new subkey $newest"
  fi
done
echo "PASS: GnuPG took every change and every certificate"
