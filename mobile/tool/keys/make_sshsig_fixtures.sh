#!/bin/sh
# Made the SSH signature files in test/fixtures/keys/openssh/sshsig once, on
# 2026-11-16, with OpenSSH 10.3 and git 2.55 (add-ssh-signatures, task 1.1).
# The ECDSA signatures are random, so running this again makes different
# files: the committed ones are never regenerated, and this script is kept
# as the exact record of how they were made. It refuses to write into a
# directory that exists.
#
# It signs with the unprotected keys of test/fixtures/keys/openssh, which it
# only reads: `ssh-keygen` refuses a key file others can read, so the keys
# are copied to a temporary folder and restricted there.
#
# Run it from mobile/ (needs ssh-keygen and git):
#
#   tool/keys/make_sshsig_fixtures.sh [new directory]
#
# The directory defaults to test/fixtures/keys/openssh/sshsig.

set -eu

KEYS=test/fixtures/keys/openssh
OUT=${1:-$KEYS/sshsig}
CUSTOM='kemlock-test@example.org'

if [ -e "$OUT" ]; then
  echo "$OUT exists; the fixtures are never regenerated" >&2
  exit 1
fi
[ -f "$KEYS/ed25519" ] || { echo "run this from mobile/" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kemlock-sshsig.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"
for k in ed25519 rsa3072 ecdsa256 ecdsa384 ecdsa521; do
  # A checkout that turned the key's line endings into CRLF (the fixtures
  # are LF in git) gives a file ssh-keygen cannot load.
  tr -d '\r' < "$KEYS/$k" > "$WORK/$k"
  tr -d '\r' < "$KEYS/$k.pub" > "$WORK/$k.pub"
  chmod 600 "$WORK/$k"
done

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
{
  ssh -V 2>&1
  git --version
} > "$OUT/versions.txt"

# ─── The messages ─────────────────────────────────────────────────────────────
: > "$OUT/empty"
printf 'hello' > "$OUT/hello.txt"
# The 256 byte values, in order.
i=0
: > "$OUT/bytes.bin"
while [ $i -lt 256 ]; do
  printf "\\$(printf '%03o' $i)" >> "$OUT/bytes.bin"
  i=$((i + 1))
done

# ─── ssh-keygen -Y sign ───────────────────────────────────────────────────────
# <key>-<variant>-<message>.sig, the variant being the namespace (`file`,
# `git`, `custom` for $CUSTOM) or, for the namespace `file` hashed with
# SHA-256 instead of ssh-keygen's SHA-512, `sha256`.
sign() { # key variant namespace message [option...]
  key=$1 variant=$2 namespace=$3 message=$4
  shift 4
  cp "$OUT/$message" "$WORK/message"
  rm -f "$WORK/message.sig"
  ssh-keygen -q -Y sign -f "$WORK/$key" -n "$namespace" "$@" "$WORK/message" 2> "$WORK/stderr" || { cat "$WORK/stderr" >&2; exit 1; }
  mv "$WORK/message.sig" "$OUT/$key-$variant-$message.sig"
  printf '%s: ' "$key-$variant-$message.sig"
  ssh-keygen -Y check-novalidate -n "$namespace" -s "$OUT/$key-$variant-$message.sig" < "$OUT/$message"
}
for message in empty hello.txt bytes.bin; do
  for key in ed25519 rsa3072 ecdsa256 ecdsa384 ecdsa521; do
    sign $key file file $message
  done
  sign ed25519 git git $message
  sign ed25519 custom "$CUSTOM" $message
  sign ed25519 sha256 file $message -O hashalg=sha256
done

# ─── git ──────────────────────────────────────────────────────────────────────
# A commit and a tag signed by the ed25519 key, as `git cat-file` prints
# them. Nothing of the machine's git configuration is read.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME='Fixture Author' GIT_AUTHOR_EMAIL=author@example.org GIT_AUTHOR_DATE='2026-11-16T12:00:00+00:00'
export GIT_COMMITTER_NAME='Fixture Committer' GIT_COMMITTER_EMAIL=committer@example.org GIT_COMMITTER_DATE='2026-11-16T12:00:00+00:00'
REPO="$WORK/repo"
git init -q -b main "$REPO"
g() { git -C "$REPO" -c gpg.format=ssh -c user.signingkey="$WORK/ed25519" -c gpg.ssh.allowedSignersFile="$WORK/allowed_signers" "$@"; }
printf 'committer@example.org %s\n' "$(cut -d' ' -f1,2 "$WORK/ed25519.pub")" > "$WORK/allowed_signers"
printf 'hello' > "$REPO/hello.txt"
g add hello.txt
g commit -q -S -m 'Add a greeting' -m 'The body of the fixture commit.'
g tag -s -m 'The first fixture tag' v1
g cat-file commit HEAD > "$OUT/git-commit.txt"
g cat-file tag v1 > "$OUT/git-tag.txt"
g rev-parse HEAD > "$OUT/git-commit.id.txt"
g rev-parse v1 > "$OUT/git-tag.id.txt"
g verify-commit HEAD 2>&1 | sed 's/^/git-commit.txt: /'
g verify-tag v1 2>&1 | sed 's/^/git-tag.txt: /'

echo "wrote $(ls "$OUT" | wc -l | tr -d ' ') files to $OUT"
